//! Windows toast notification provider: the real `Windows.UI.Notifications`
//! platform, behind the shared `notifications.NotificationProvider` contract.
//!
//! What Windows has, and what it does not, decides the shape of this adapter.
//!
//! * Identity is the toast **tag**. `put_Tag` with a tag the app already used
//!   replaces the previous toast in place, which is exactly what
//!   `NotificationOptions.replaces_id` means. So the provider owns a monotonic id
//!   table, hands each notification a tag derived from its id, and a replace
//!   reuses the replaced notification's tag rather than minting a new one. The
//!   shared service then drops the old id and tracks the new one, so the two
//!   halves agree.
//! * Dismissal is `IToastNotifier::Hide` for a toast the shim still holds plus
//!   `IToastNotificationHistory::RemoveGroupedTagWithId` for Action Center.
//!   Windows has no API that retracts a toast whose object the app has already
//!   released, so a dismissal can always clear history and can retract the
//!   banner only while the toast is still held; the shim holds the most recent
//!   few and says so. A toast that carries a tag can therefore be dismissed and
//!   is reported as `closed`; a toast with no tag cannot be named, and `dismiss`
//!   returns `DismissOutcome.refused`, leaving the notification tracked.
//!   A permission, protocol or provider failure is reported separately; none
//!   is a simulated dismissal.
//! * Action delivery is a COM activation handler. Windows asks the *running*
//!   process, through `INotificationActivationCallback`, to handle the
//!   activation. That callback arrives on a thread the shell chooses, so it
//!   copies the argument into a bounded owned ring and touches nothing else.
//!   The ring is replayed on the host's own thread when the shared service
//!   drives this provider through its `poll`, which is the whole of what a host
//!   has to do: it handed the provider to the service and keeps no reference to
//!   it. No application state is touched from the shell's thread.
//!
//! * Handing that registration back is a barrier, not a flag.
//!   `nogui_toast_activator_unregister` returns only once every activation that
//!   had already taken the callback has run it and returned, so a provider whose
//!   registration was released is one no shell thread can enter again. `deinit`
//!   relies on that to free the block the COM context points at, and the
//!   `is_gone` latch cannot do it instead: a latch is a value read through a
//!   pointer this provider owns, and the pointer is what is going away.
//!
//! * There is one activation registration per process, not one per provider. COM
//!   keeps a single class object, cookie, callback and context for an
//!   activation, so a second provider that asks cannot have one of its own
//!   without taking the first provider's. The lease is counted here, where the
//!   decision is made and can be checked on any target, and the provider that
//!   does not hold it says so through `activatorOf` instead of claiming an
//!   action no click will ever reach.
//!
//! **Packaging is a real prerequisite, and it is reported rather than assumed.** A
//! desktop toast needs a Start menu shortcut whose `System.AppUserModel.ID` is the
//! claimed AppUserModelID, and Windows fails *silently* without one: the toast
//! simply never appears, with no HRESULT to inspect afterwards. So the provider
//! asks the platform instead, through `IToastNotifier::get_Setting`, which is the
//! documented way to know whether notifications are enabled for an identity. An
//! identity that is switched off yields a provider that claims no capability and
//! refuses every submit with `denied`, and `blockerOf` names the party that
//! switched it off. What no adapter can verify is the shortcut itself, which is
//! an installer fact; the header of the shim says so where the packaging lives.
//!
//! The argument the shell hands back is the host's own, and it is
//! self-describing: `<notification id>|<action key length>|<action key>`. The
//! length prefix is what makes it unambiguous, so an action key that contains
//! the separator character still routes to the notification that owns it rather
//! than to whichever notification happened to parse.
//!
//! Outcome mapping, stated rather than guessed:
//!
//!   * `NOGUI_TOAST_UNAVAILABLE` is `SubmitOutcome.unsupported`. The platform is
//!     not reachable for this identity: WinRT is absent, or no notification
//!     endpoint claims the AppUserModelID. Nothing was shown.
//!   * `NOGUI_TOAST_DENIED` is `SubmitOutcome.denied`. The platform answered
//!     and its answer was no, which is a different thing from having nothing to
//!     answer with. This is what a blocked identity produces.
//!   * `NOGUI_TOAST_INVALID` is `provider_failed = .protocol_error`: the toast
//!     XML was rejected, or the host passed a value Windows cannot use, such as
//!     a tag past the platform's length limit.
//!   * `NOGUI_TOAST_FAILED` is `provider_failed = .rejected`.
//!
//! Fields Windows has no channel for are handled by name rather than dropped.
//! `timeout_ms`, `sound`, `category` and `app_name` have no per-toast
//! equivalent and are documented as ignored. Three things are **refused** rather
//! than quietly degraded, because a caller that asked for them would otherwise
//! get a weaker notification than it asked for and no signal that it did:
//! `urgency = .critical`, an `icon` that is not a URI the toast platform can
//! fetch, and more action buttons than a desktop toast renders.
const std = @import("std");
const win = @import("win32.zig");
const app_identity = @import("app_identity.zig");
const notifications = @import("../notifications.zig");

const NotificationId = notifications.NotificationId;
const NotificationOptions = notifications.NotificationOptions;
const SubmitOutcome = notifications.SubmitOutcome;
const Capabilities = notifications.Capabilities;

/// A desktop toast renders at most this many action buttons. A request for
/// more is refused rather than truncated, so no action is silently lost.
pub const max_actions: usize = 3;

/// Narrow C ABI of `native/nogui_toast.c`, which is where the WinRT calls
/// live. The header is plain C declarations, so these are the exact symbols the
/// shim exports.
pub const ToastStatus = enum(c_int) {
    ok = 0,
    unavailable = 1,
    denied = 2,
    invalid = 3,
    failed = 4,
    /// Another provider in this process already holds the one activation
    /// registration a process has. Nothing of that provider's is taken, and the
    /// registration stays live for it.
    busy = 5,
};

pub const Activation = extern struct {
    /// NUL-terminated UTF-8, owned by the shim for the duration of the call.
    argument: ?[*:0]const u8,
    is_body: bool,
};

pub const ActivationFn = *const fn (user: ?*anyopaque, event: *const Activation) callconv(.c) void;

/// Why the platform will not show toasts for this identity, as the platform's
/// own `get_Setting` reports it. Mirrors `nogui_toast_blocker`.
pub const Blocker = enum(c_int) {
    none = 0,
    disabled_by_manifest = 1,
    disabled_by_group_policy = 2,
    disabled_for_user = 3,
    disabled_for_application = 4,

    /// A sentence a host can show, naming the party that switched toasts off.
    pub fn reason(self: Blocker) []const u8 {
        return switch (self) {
            .none => "",
            .disabled_by_manifest => "the app manifest disables notifications",
            .disabled_by_group_policy => "group policy disables notifications",
            .disabled_for_user => "the user disabled notifications for this app",
            .disabled_for_application => "notifications are disabled for this app",
        };
    }
};

/// What `nogui_toast_probe` found. Mirrors `nogui_toast_probe_result`.
pub const ProbeResult = extern struct {
    blocker: Blocker,
    can_show: bool,
};

pub extern fn nogui_toast_runtime_init() callconv(.c) c_int;
pub extern fn nogui_toast_runtime_uninit() callconv(.c) void;
pub extern fn nogui_toast_probe(app_id: ?[*:0]const u16, out: *ProbeResult) callconv(.c) ToastStatus;
pub extern fn nogui_toast_show(
    app_id: ?[*:0]const u16,
    xml: ?[*:0]const u16,
    tag: ?[*:0]const u16,
    group: ?[*:0]const u16,
) callconv(.c) ToastStatus;
pub extern fn nogui_toast_remove(
    app_id: ?[*:0]const u16,
    tag: ?[*:0]const u16,
    group: ?[*:0]const u16,
) callconv(.c) ToastStatus;
pub extern fn nogui_toast_activator_register(
    app_id: ?[*:0]const u16,
    cls_id: ?[*:0]const u16,
    callback: ?ActivationFn,
    user: ?*anyopaque,
) callconv(.c) ToastStatus;
pub extern fn nogui_toast_activator_unregister() callconv(.c) void;

/// Native activations buffered between the shell's thread and the host's.
/// Bounded on purpose: a burst is dropped and counted rather than allowed to
/// grow, because the host drains once per frame and an undrained ring would
/// otherwise be an unbounded queue.
pub const max_queue: usize = 64;
/// Total action-key bytes the ring can own at once.
pub const max_payload_bytes: usize = 4096;

/// One buffered activation, owned by the provider. `payload_offset` indexes the
/// shared payload scratch, so no key is a pointer into a shim buffer.
const Pending = struct {
    id: NotificationId,
    is_body: bool,
    payload_offset: u32,
    payload_len: u32,
};

/// The key a body activation is reported under, so a caller that declared a
/// "default" action is what receives it.
pub const body_action_key = "default";

pub const Options = struct {
    /// The process AppUserModelID. Must match what `app_identity` set, and it
    /// is read back from the process rather than trusted from here.
    app_id: []const u8,
    /// The group every toast is filed under. Windows groups toasts in Action
    /// Center by tag and group, and a group is what keeps one app's toasts
    /// together there.
    group: []const u8 = "nogui",
    /// The COM class id, in registry form, that the shell activates for this
    /// app's toasts. The class must be registered under
    /// `HKCU\Software\Classes\CLSID\{clsid}` with a `LocalServer32` value, because
    /// that is what lets COM launch this executable; the shim checks for it and
    /// reports its absence as "no actions" rather than registering something the
    /// shell will never reach. Binding the AppUserModelID to the class is the
    /// installer's job, through the Start menu shortcut's
    /// `System.AppUserModel.ToastActivatorCLSID` property.
    activator_cls_id: []const u8 = "",
};

/// What this provider's COM activation registration is doing.
///
/// Every value but `.ready` means the same thing to a caller: a user click on
/// one of this provider's toasts cannot reach it, so `capabilities.actions` is
/// false and no caller waits for a response that cannot arrive. The values
/// exist so a host can say which of those reasons applies rather than reporting
/// a missing capability with nothing behind it.
pub const Activator = enum {
    /// This provider holds no registration: it was built without a class id, or
    /// it gave its lease back. A toast still shows; its buttons are simply not
    /// something the app will ever hear about.
    none,
    /// This provider holds the process's registration, so a user click on one
    /// of its toasts reaches it.
    ready,
    /// The class is not registered under `HKCU\Software\Classes\CLSID` with a
    /// `LocalServer32` that points at an executable, so COM cannot launch this
    /// process to activate a toast. An installer creates that and nothing at
    /// runtime can work around it.
    class_missing,
    /// Another provider in this process already holds the one registration a
    /// process has. That provider keeps it: nothing was taken from it, and a
    /// second provider must not leave the first claiming an action it can no
    /// longer be handed.
    already_registered,
    /// The registration was refused for another reason the shim names: a class
    /// id it cannot parse, or a platform failure it calls retryable.
    refused,
};

/// The refusal a status names. Every status is accounted for, so a status the
/// shim adds later cannot be read as a registration that worked.
fn activatorFromStatus(status: ToastStatus) Activator {
    return switch (status) {
        .ok => .ready,
        .unavailable => .class_missing,
        .busy => .already_registered,
        .invalid, .failed, .denied => .refused,
    };
}

/// The provider holding the process's one activation registration.
///
/// COM keeps one class object, cookie, callback and context for an activation,
/// so this is a process-wide resource and the table that owns it is
/// process-wide too. `null` means no provider holds it and the next provider to
/// ask for it takes it.
var activator_lease: ?*Provider = null;
/// Guards `activator_lease` only, and is locked with the calling provider's own
/// `std.Io`, because that is the instance this file already shares with the
/// host. Providers are built and torn down on the host's thread, but a lease two
/// threads race for must still name one winner.
var activator_mutex: std.Io.Mutex = .init;

pub const Error = error{
    /// No AppUserModelID is set on the process, or it is not the one `Options`
    /// names. A toast attributed to the wrong identity is worse than none.
    IdentityMismatch,
    /// The identity string is not one the shell will accept.
    InvalidAppId,
    /// The group is not valid UTF-8, so it cannot be widened for the shell. The
    /// identity is held to the shell's own grammar first; the group is caller
    /// text, and a mangled group is a group the toasts are filed under that the
    /// caller did not ask for.
    InvalidUtf8,
    /// The platform is not reachable for this identity: WinRT is absent, or the
    /// platform will not attribute a toast to it. An identity whose notifications
    /// are switched off is *not* this error; that is a provider that exists and
    /// refuses, which `blockerOf` explains.
    Unavailable,
} || std.mem.Allocator.Error;

/// One live toast table. The handle is what `NotificationsService` holds.
pub const Provider = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    options: Options,
    /// The AppUserModelID this provider answers for, owned. Null on a build
    /// that has no shell to claim one for, and a provider that owns nothing
    /// is a provider with nothing to release.
    app_id: ?[]u8,
    /// The widened identity and group, owned. The shell takes wide strings, so
    /// these exist only where there is a shell to hand them to; a build without
    /// one never widens anything and therefore never allocates.
    wide_app_id: ?[:0]u16,
    wide_group: ?[:0]u16,
    /// What the platform says about this identity. Anything but `.none` means
    /// toasts are switched off, which is a different answer from "the platform is
    /// not there", and it is kept rather than flattened so a host can say who
    /// switched them off.
    blocker: Blocker = .none,
    /// True when this provider initialized WinRT and therefore owes the matching
    /// `nogui_toast_runtime_uninit`. A thread that already had a runtime is not
    /// this provider's to tear down.
    owns_runtime: bool = false,
    /// What this provider's activation registration is doing, and therefore
    /// whether a user click can reach it. Public because a host asked to explain
    /// a toast whose buttons stay silent needs the reason, and "no actions" with
    /// nothing behind it is not one.
    activator: Activator = .none,
    /// Latched by `disconnect` under the ring's own lock. A provider that
    /// released its identity is not reconnected by a late call, and an
    /// activation that lands afterwards is refused rather than buffered into a
    /// ring nothing will drain again.
    is_gone: bool = false,
    /// Zero is reserved so a tag is never an empty string.
    next_id: NotificationId = 1,
    /// The ids this provider has actually shown. A dismissal is only possible
    /// for an id in here, which is what makes "nothing was removed" reportable.
    shown: std.AutoHashMapUnmanaged(NotificationId, void) = .empty,

    mutex: std.Io.Mutex = .init,
    queue: [max_queue]Pending,
    queue_len: u32 = 0,
    queue_head: u32 = 0,
    payload: [max_payload_bytes]u8,
    payload_used: u32 = 0,
    /// Activations the ring refused because it was full. Surfaced, never
    /// hidden: a lost activation is a user click that went nowhere.
    dropped: u32 = 0,
    pending: bool = false,
    /// Deliveries holding a borrowed action key out of `payload`. The scratch
    /// is handed back only once the ring is empty and no delivery is still on
    /// the stack, which is what keeps a nested pump from overwriting the key
    /// the live callback is still reading.
    in_flight: u32 = 0,

    /// Build a provider at a stable address, and return the pointer to it.
    ///
    /// The identity is verified against the process before any WinRT call, so a
    /// mismatch is a named refusal and not a toast the shell attributes to a
    /// different app's Start menu entry.
    ///
    /// The provider is heap-allocated rather than returned by value, because two
    /// things outlive the caller's frame and hold this address: the COM
    /// activation handler is handed this address as its context for as long as
    /// the class object is registered, and the notifications service keeps the
    /// vtable pointer until its own `deinit`. A provider returned by value would
    /// be copied into that frame, and both of them would then be pointing at a
    /// stack slot the call has already left.
    pub fn init(gpa: std.mem.Allocator, io: std.Io, options: Options) Error!*Provider {
        if (!app_identity.isWellFormed(options.app_id)) return error.InvalidAppId;

        const self = try gpa.create(Provider);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .io = io,
            .options = options,
            .app_id = null,
            .wide_app_id = null,
            .wide_group = null,
            // SAFETY: `queue` is a scratch ring whose live prefix is tracked by
            // `queue_len`, which this initializer leaves at 0, so no slot is
            // read before the shell's thread writes it.
            .queue = undefined,
            // SAFETY: `payload` is scratch bytes whose live prefix is tracked by
            // `payload_used`, which this initializer leaves at 0, so no byte is
            // read before the shell's thread writes it.
            .payload = undefined,
        };
        errdefer self.releaseStrings();

        // One activation registration per process, leased rather than
        // registered: see `takeActivatorLease`. It is taken once everything this
        // call needs exists, because it names the widened identity, and released
        // again by `deinit` or `disconnect` whoever owns it.

        if (comptime !win.is_windows) {
            // Off Windows there is no shell, so nothing is initialized, nothing
            // is widened and nothing is owned. An empty widened string is not a
            // buffer worth allocating: no call on this build reaches the shell,
            // so a provider that held one would own an allocation that exists
            // only to be freed again. The provider still exists and still answers
            // every call by name.

            // The lease is the same table on every target: it is bookkeeping,
            // and only the COM call behind it needs a shell. Taking it here
            // keeps the table's behaviour identical on both, which is what lets
            // a check on one platform mean anything on the other.
            self.activator = try self.takeActivatorLease(options.activator_cls_id);
            errdefer self.releaseActivatorLease();
            return self;
        }

        const current = (try app_identity.currentProcessIdentity(gpa)) orelse
            return error.IdentityMismatch;
        defer current.deinit();
        if (!std.mem.eql(u8, current.app_id, options.app_id)) return error.IdentityMismatch;

        self.app_id = try gpa.dupe(u8, options.app_id);
        self.wide_app_id = try win.wide(gpa, options.app_id);
        self.wide_group = try win.wide(gpa, options.group);

        // The runtime is initialized for this thread and balanced at teardown only
        // when this call is the one that started it, so a host that already had
        // WinRT keeps its own.
        const runtime = nogui_toast_runtime_init();
        if (runtime < 0) return error.Unavailable;
        self.owns_runtime = runtime == 1;

        var probe: ProbeResult = .{ .blocker = .none, .can_show = false };
        switch (nogui_toast_probe(self.wide_app_id.?.ptr, &probe)) {
            // The platform will show toasts for this identity, and `blocker`
            // already says as much.
            .ok => {},
            .unavailable => {
                // The platform answered that it will not attribute a toast to this
                // identity, which is the packaging prerequisite failing. Told here
                // rather than at the first submit.
                self.uninitRuntime();
                return error.Unavailable;
            },
            // Switched off by manifest, policy, user or application. That is not a
            // missing platform, so the provider still exists and reports the
            // blocker, and a submit is refused by the platform rather than by a
            // missing capability.
            .denied => {
                self.blocker = probe.blocker;
            },
            .invalid => {
                self.uninitRuntime();
                return error.InvalidAppId;
            },
            // A probe never registers anything, so the shim reporting the one
            // registration as taken means it refused a question that was not
            // asked. There is no identity to attribute a toast to.
            .busy => {
                self.uninitRuntime();
                return error.Unavailable;
            },
            .failed => {
                self.uninitRuntime();
                return error.OutOfMemory;
            },
        }

        self.activator = try self.takeActivatorLease(options.activator_cls_id);
        errdefer self.releaseActivatorLease();

        return self;
    }

    /// Why the platform will not show a toast for this identity, or `.none` when
    /// it will. Public because a host asked to explain a silent notification needs
    /// the party that switched it off, not a bare "unsupported".
    pub fn blockerOf(self: *Provider) Blocker {
        return self.blocker;
    }

    /// What this provider's activation registration is doing. Public because a
    /// toast whose buttons stay silent is otherwise a missing capability with
    /// nothing behind it, and the packaging case and the two-providers case
    /// need different things from a host.
    pub fn activatorOf(self: *const Provider) Activator {
        return self.activator;
    }

    /// Ask for the process's one activation registration, and report what this
    /// provider got.
    ///
    /// The lease is taken here rather than inside the shim because the decision
    /// is a policy about one process-wide resource, and a policy that lives in
    /// one place is one two providers cannot disagree about. The shim keeps the
    /// COM half and refuses a conflicting registration of its own account, so a
    /// caller that never came through here still cannot take another's
    /// callback.
    ///
    /// A refused registration is not fatal for showing toasts. A toast with no
    /// activator still shows; its buttons are simply not something the app will
    /// ever hear about, and `capabilities` then reports `actions = false` so no
    /// caller waits for a response that cannot arrive.
    fn takeActivatorLease(self: *Provider, cls_id: []const u8) Error!Activator {
        if (cls_id.len == 0) return .none;

        activator_mutex.lockUncancelable(self.io);
        defer activator_mutex.unlock(self.io);
        // The registration belongs to whoever took it. Saying so is what keeps
        // a second provider from claiming actions it cannot be handed, and what
        // keeps it from overwriting a callback that is still live.
        if (activator_lease != null) return .already_registered;

        if (comptime win.is_windows) {
            const wide_cls = try win.wide(self.gpa, cls_id);
            defer self.gpa.free(wide_cls);
            const status = nogui_toast_activator_register(
                self.wide_app_id.?.ptr,
                wide_cls.ptr,
                activationCallback,
                self,
            );
            if (status != .ok) return activatorFromStatus(status);
        }
        activator_lease = self;
        return .ready;
    }

    /// Give the registration back, and only if this provider holds it.
    ///
    /// Releasing is idempotent and takes the lease before calling the shim, so a
    /// provider that never held one cannot revoke another provider's class
    /// object, and a second `disconnect` after `deinit` cannot unbalance the
    /// shim's single registration.
    ///
    /// The shim call is a barrier and not a flag: it returns only after every
    /// activation that had already taken this provider as its callback context
    /// has run and returned. That is what lets `deinit` free the block straight
    /// after this call, and it is why nothing on this side has to count shell
    /// threads of its own. The wait cannot close on itself: the native handler
    /// reaches this provider through nothing but `mutex`, and no caller of this
    /// function holds `mutex`, so the thread being waited for can always finish.
    fn releaseActivatorLease(self: *Provider) void {
        activator_mutex.lockUncancelable(self.io);
        defer activator_mutex.unlock(self.io);
        if (activator_lease != self) return;
        activator_lease = null;
        self.activator = .none;
        if (comptime win.is_windows) nogui_toast_activator_unregister();
    }

    /// Give back the runtime, and only the one this provider started.
    ///
    /// The shim's uninit decrements a process-wide depth and calls
    /// `RoUninitialize` when it reaches zero, so a provider whose `init` was told
    /// the thread already had a usable apartment must not call it: that apartment
    /// belongs to the host, and one unbalanced decrement would take the host's
    /// WinRT down with this provider's own failure.
    fn uninitRuntime(self: *Provider) void {
        if (!self.owns_runtime) return;
        nogui_toast_runtime_uninit();
        self.owns_runtime = false;
    }

    fn releaseStrings(self: *Provider) void {
        // Each field is cleared as it is freed, so a second release is a no-op
        // rather than a double free, and a provider that was never given one
        // has nothing to release.
        if (self.app_id) |bytes| {
            self.gpa.free(bytes);
            self.app_id = null;
        }
        if (self.wide_app_id) |wide| {
            self.gpa.free(wide);
            self.wide_app_id = null;
        }
        if (self.wide_group) |wide| {
            self.gpa.free(wide);
            self.wide_group = null;
        }
    }

    /// Release the provider and the block it lives in.
    ///
    /// One call ends everything this provider owns: the COM class object, the
    /// runtime it started, the id table and the strings. A caller that only
    /// wants the shell side gone asks for `disconnect`, which is the latch the
    /// shared contract gives it, and can still use the provider afterwards.
    ///
    /// The order is what makes the release safe. The registration goes first,
    /// and that call is a barrier: when it returns no shell thread can name this
    /// provider again, so the runtime, the id table and the block below it are
    /// all unreachable from the shell before any of them is gone.
    pub fn deinit(self: *Provider) void {
        const gpa = self.gpa;
        // The class object is revoked, and every activation that could still
        // name this provider is waited out, before the runtime it was registered
        // in goes, and only by the provider that actually holds the
        // registration.
        self.releaseActivatorLease();
        if (comptime win.is_windows) self.uninitRuntime();
        self.shown.deinit(gpa);
        self.releaseStrings();
        defer gpa.destroy(self);
        self.* = undefined;
    }

    pub fn provider(self: *Provider) notifications.NotificationProvider {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: notifications.NotificationProvider.VTable = .{
        .submit = submitImpl,
        .dismiss = dismissImpl,
        .getCapabilities = capabilitiesImpl,
        .disconnect = disconnectImpl,
        .deinit = deinitImpl,
        .poll = pollFn,
    };

    fn disconnectImpl(ctx: *anyopaque) void {
        const self: *Provider = @ptrCast(@alignCast(ctx));
        // Latched under the ring's lock, because the shell's thread reads the
        // same latch when an activation lands. The latch is about answers and
        // not about memory: it stops a late click being buffered into a ring
        // nothing will drain again. What makes the storage itself safe is the
        // release below, which returns only once no activation can name this
        // provider. A latch cannot do that job, because a value read through a
        // pointer this provider owns is not something a freed provider can
        // still be asked about.
        self.mutex.lockUncancelable(self.io);
        self.is_gone = true;
        self.mutex.unlock(self.io);
        self.releaseActivatorLease();
        if (comptime win.is_windows) {
            // The shell is no longer reachable through this provider, so no later
            // activation is delivered into it and the runtime it started goes.
            self.uninitRuntime();
        }
    }

    fn deinitImpl(ctx: *anyopaque) void {
        const self: *Provider = @ptrCast(@alignCast(ctx));
        self.deinit();
    }

    /// What this platform can actually do.
    ///
    /// `actions` is only claimed when a COM activator is registered, because the
    /// shared contract's whole point is that a claimed capability is one a user
    /// response can reach. A toast with no activator still shows; its buttons
    /// are not something the app will ever hear about, and claiming otherwise
    /// would strand a user click.
    ///
    /// `body_markup` and `body_hyperlinks` are false because the body is
    /// published as escaped text, not parsed as markup. `body_images` is true
    /// because the toast XML carries an `<image>` when the caller supplied a URI
    /// the platform can fetch. `sound` is false: a toast has no per-toast sound
    /// control. `persistence` is true: a toast stays in Action Center until the
    /// user clears it or the system expires it.
    fn capabilitiesImpl(ctx: *anyopaque) Capabilities {
        const self: *Provider = @ptrCast(@alignCast(ctx));
        if (comptime !win.is_windows) return .none;
        if (self.is_gone) return .none;
        // An identity whose notifications are switched off can do nothing, so it
        // claims nothing. `blockerOf` is where a host learns why.
        if (self.blocker != .none) return .none;
        return .{
            .body = true,
            .body_images = true,
            .actions = self.activator == .ready,
            .persistence = true,
        };
    }

    fn submitImpl(ctx: *anyopaque, options: NotificationOptions) SubmitOutcome {
        const self: *Provider = @ptrCast(@alignCast(ctx));
        if (comptime !win.is_windows) return .unsupported;
        if (self.is_gone) return .{ .provider_failed = .disconnected };
        // Switched off is the platform refusing, which is `denied` and not
        // `unsupported`: the platform is there and its answer is no.
        if (self.blocker != .none) return .denied;

        // Windows has one notification channel, so there is nowhere to carry an
        // urgency. A critical alert is refused rather than quietly demoted to an
        // ordinary one.
        if (options.urgency == .critical) return .{ .provider_failed = .rejected };
        if (options.actions.len > max_actions) return .{ .provider_failed = .rejected };

        var icon: ?[:0]u16 = null;
        defer if (icon) |uri| self.gpa.free(uri);
        switch (imageUriOf(self.gpa, options.icon)) {
            .none => {},
            .uri => |uri| icon = uri,
            .unusable => return .{ .provider_failed = .rejected },
        }

        const id = if (options.replaces_id) |old| blk: {
            // A replace reuses the replaced notification's tag, so the shell
            // replaces the toast in place. An id this provider never showed
            // cannot be replaced, and minting a new tag would leave the old
            // toast on screen next to its replacement forever.
            if (!self.shown.contains(old)) return .{ .provider_failed = .rejected };
            break :blk old;
        } else self.nextId();

        const xml = self.buildXml(options, id, icon) catch
            return .{ .provider_failed = .out_of_memory };
        defer self.gpa.free(xml);
        const wide_xml = win.wide(self.gpa, xml) catch return .{ .provider_failed = .out_of_memory };
        defer self.gpa.free(wide_xml);
        const tag = std.fmt.allocPrint(self.gpa, "{d}", .{id}) catch
            return .{ .provider_failed = .out_of_memory };
        defer self.gpa.free(tag);
        const wide_tag = win.wide(self.gpa, tag) catch return .{ .provider_failed = .out_of_memory };
        defer self.gpa.free(wide_tag);

        // The identity travels with the call: the shim creates the notifier for it
        // on the calling thread, so a submit from any thread is correct and no
        // notifier outlives the call.
        switch (nogui_toast_show(
            self.wide_app_id.?.ptr,
            wide_xml.ptr,
            wide_tag.ptr,
            self.wide_group.?.ptr,
        )) {
            .ok => {},
            .unavailable => return .unsupported,
            .denied => return .denied,
            .invalid => return .{ .provider_failed = .protocol_error },
            // Showing a toast never asks for the activation registration, so the
            // shim answering "busy" here means it refused something that was
            // not asked for. A toast that did not appear is a failed show.
            .busy => return .{ .provider_failed = .rejected },
            .failed => return .{ .provider_failed = .rejected },
        }

        // The id is only recorded once the platform accepted the toast, so a
        // failed submit leaves nothing a later dismiss could half-honour.
        self.shown.put(self.gpa, id, {}) catch return .{ .provider_failed = .out_of_memory };
        return .{ .accepted = id };
    }

    fn nextId(self: *Provider) NotificationId {
        const id = self.next_id;
        // Wrapping past the table would alias a live id, so the counter stops
        // one short of the end and the caller sees the exhaustion as a refusal.
        self.next_id = if (self.next_id == std.math.maxInt(NotificationId))
            std.math.maxInt(NotificationId)
        else
            self.next_id + 1;
        return id;
    }

    /// Dismiss the toast: retract the banner the shim still holds, then clear the
    /// Action Center entry.
    ///
    /// Only `ok` is a close. A refusal is a refusal on this platform too: a
    /// toast with no tag, an id this provider never showed, or a platform
    /// without per-tag history all leave the notification where it is, so the
    /// shared contract keeps it tracked and a caller that reads them as closed
    /// waits on actions nothing will answer.
    ///
    /// Everything else is named rather than folded into that refusal, because
    /// none of it is the platform declining: an identity the platform refuses to
    /// touch is an authorization refusal, a rejected tag is a protocol error,
    /// and a transport that failed or a provider that is gone cannot say
    /// anything about the toast.
    fn dismissImpl(ctx: *anyopaque, id: NotificationId) notifications.DismissOutcome {
        const self: *Provider = @ptrCast(@alignCast(ctx));
        if (comptime !win.is_windows) return .unsupported;
        if (self.is_gone) return .{ .provider_failed = .disconnected };
        if (!self.shown.contains(id)) return .refused;

        const tag = std.fmt.allocPrint(self.gpa, "{d}", .{id}) catch
            return .{ .provider_failed = .out_of_memory };
        defer self.gpa.free(tag);
        const wide_tag = win.wide(self.gpa, tag) catch
            return .{ .provider_failed = .out_of_memory };
        defer self.gpa.free(wide_tag);

        return switch (nogui_toast_remove(
            self.wide_app_id.?.ptr,
            wide_tag.ptr,
            self.wide_group.?.ptr,
        )) {
            .ok => .closed,
            // The platform has no per-tag history, so the entry is still in
            // Action Center: nothing was removed.
            .unavailable => .refused,
            .denied => .{ .provider_failed = .permission_denied },
            .invalid => .{ .provider_failed = .protocol_error },
            // Removing a toast never asks for the activation registration, so
            // the shim answering "busy" here refused something not asked for.
            .busy, .failed => .{ .provider_failed = .rejected },
        };
    }

    /// True while the shell's thread has delivered an activation the host has
    /// not drained. The service reads the same state by driving this provider,
    /// so a host only needs it to explain a queue it is not pumping.
    pub fn hasPending(self: *Provider) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.pending;
    }

    /// Activations the bounded ring refused. Surfaced rather than hidden, so a
    /// host can tell a user whose click went nowhere.
    pub fn droppedActivations(self: *Provider) u32 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.dropped;
    }

    /// Replay every buffered activation on the calling (host) thread.
    ///
    /// This is the whole of the marshalling. The shell's thread only ever copied
    /// bytes into the ring, and this is where they become responses, so one
    /// model is mutated from one thread. The key handed to the service is
    /// borrowed from the ring's payload and is valid only for the duration of
    /// the callback, which is what the service documents.
    ///
    /// The service drives this through the provider contract, so a host that
    /// handed the provider over has nothing to call and no reference to keep.
    pub fn drain(self: *Provider, service: *notifications.NotificationsService) usize {
        var delivered: usize = 0;
        while (true) {
            self.mutex.lockUncancelable(self.io);
            if (self.queue_len == 0) {
                self.pending = false;
                self.mutex.unlock(self.io);
                break;
            }
            const entry = self.queue[self.queue_head];
            self.queue_head = (self.queue_head + 1) % @as(u32, @intCast(max_queue));
            self.queue_len -= 1;
            // Counted before the lock drops: this delivery is about to hold a
            // borrowed key out of the payload, and a handler that pumps again
            // re-enters this loop with this delivery still counted. Without the
            // count that nested drain empties the ring and hands the scratch
            // back under the callback that is still reading it.
            self.in_flight += 1;
            self.mutex.unlock(self.io);

            const key = self.payload[entry.payload_offset .. entry.payload_offset + entry.payload_len];
            service.handleResponse(entry.id, .{
                .action = .{ .key = if (entry.is_body) body_action_key else key },
            });
            delivered += 1;

            self.mutex.lockUncancelable(self.io);
            self.in_flight -= 1;
            self.mutex.unlock(self.io);
            self.reclaimPayload();
        }
        return delivered;
    }

    /// The drain behind the provider contract.
    ///
    /// The timeout means nothing here: the ring is filled by the shell's own
    /// thread, so there is never anything to wait for.
    fn pollFn(
        ctx: *anyopaque,
        service: *notifications.NotificationsService,
        timeout_ms: i32,
    ) anyerror!usize {
        _ = timeout_ms;
        const self: *Provider = @ptrCast(@alignCast(ctx));
        return self.drain(service);
    }

    /// Hand the payload scratch back once the ring has nothing left in it and
    /// no delivery is still holding a key out of it.
    ///
    /// The watermark is what tells the shell's thread where the next activation
    /// may write, so it may only drop to zero while the ring is empty, and the
    /// ring is read here under the same lock the producer takes. An activation
    /// that arrived while the previous one was being delivered owns bytes at the
    /// old watermark, and zeroing it here would let the activation after that
    /// one write over them: the host would be handed a different action key for
    /// the notification the user actually clicked.
    ///
    /// An empty ring alone does not mean every delivery finished. A handler is
    /// the host's own code and may pump again from inside the callback that is
    /// still reading its borrowed key, and that nested drain empties the ring
    /// first. So the deliveries in flight are counted, and the scratch waits for
    /// the last of them.
    ///
    /// The bytes themselves are not cleared, because the key the service has
    /// just been handed is still borrowed from them.
    fn reclaimPayload(self: *Provider) void {
        self.mutex.lockUncancelable(self.io);
        if (self.queue_len == 0 and self.in_flight == 0) self.payload_used = 0;
        self.mutex.unlock(self.io);
    }

    /// Copies one activation into the bounded ring. Runs on the shell's thread
    /// and touches nothing but the provider's own ring.
    fn activationCallback(user: ?*anyopaque, event: *const Activation) callconv(.c) void {
        const self: *Provider = @ptrCast(@alignCast(user orelse return));
        const argument = if (event.argument) |a| std.mem.span(a) else "";

        var id: NotificationId = 0;
        var key: []const u8 = "";
        var is_body = true;
        if (decodeArgument(argument)) |parsed| {
            id = parsed.id;
            key = parsed.key;
            is_body = false;
        }

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        // A retired provider is never reconnected by a late click. Buffering
        // here would latch `pending` and the payload watermark for a ring no
        // pump will drain again, and the user is told nothing about it.
        if (self.is_gone) return;
        if (self.queue_len == max_queue or
            self.payload_used + key.len > max_payload_bytes)
        {
            self.dropped += 1;
            return;
        }
        const offset: usize = self.payload_used;
        @memcpy(self.payload[offset .. offset + key.len], key);
        self.payload_used += @intCast(key.len);
        const tail = (self.queue_head + self.queue_len) % @as(u32, @intCast(max_queue));
        self.queue[tail] = .{
            .id = id,
            .is_body = is_body,
            .payload_offset = @intCast(offset),
            .payload_len = @intCast(key.len),
        };
        self.queue_len += 1;
        self.pending = true;
    }

    const ImageUri = union(enum) {
        none,
        uri: [:0]u16,
        /// A value the toast platform cannot fetch. Refused rather than dropped.
        unusable,
    };

    /// The toast XML can only carry an `<image>` the platform fetches itself, so
    /// a local filesystem path has no meaning here. A caller that passed one is
    /// told, rather than shown a toast with a missing icon.
    fn imageUriOf(gpa: std.mem.Allocator, icon: ?[]const u8) ImageUri {
        const value = icon orelse return .none;
        if (value.len == 0) return .none;
        const fetchable = std.mem.startsWith(u8, value, "http://") or
            std.mem.startsWith(u8, value, "https://") or
            std.mem.startsWith(u8, value, "ms-appx://") or
            std.mem.startsWith(u8, value, "ms-appdata://");
        if (!fetchable) return .unusable;
        return .{ .uri = win.wide(gpa, value) catch return .unusable };
    }

    /// Build the complete `<toast>` document.
    ///
    /// Every string the caller supplied is XML-escaped. A notification body is
    /// caller text, and an unescaped `&` or `<` in it is not a rendering detail:
    /// it is a document the platform will refuse, and a refusal that looks like
    /// a platform failure is the wrong thing to hand back.
    fn buildXml(
        self: *Provider,
        options: NotificationOptions,
        id: NotificationId,
        icon: ?[:0]u16,
    ) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.gpa);

        // The body activation carries its own argument rather than an empty one,
        // so a body click routes through the same table as a named action
        // instead of arriving as an id nothing recognises.
        const body_argument = try encodeArgument(self.gpa, id, body_action_key);
        defer self.gpa.free(body_argument);

        try out.print(self.gpa, "<toast launch=\"", .{});
        try escapeInto(self.gpa, &out, body_argument);
        try out.appendSlice(self.gpa, "\"><visual><binding template=\"ToastGeneric\"><text>");
        try escapeInto(self.gpa, &out, options.summary);
        try out.appendSlice(self.gpa, "</text>");
        if (options.body.len != 0) {
            try out.appendSlice(self.gpa, "<text>");
            try escapeInto(self.gpa, &out, options.body);
            try out.appendSlice(self.gpa, "</text>");
        }
        if (icon) |uri| {
            try out.appendSlice(self.gpa, "<image src=\"");
            try escapeInto(self.gpa, &out, std.mem.sliceTo(uri, 0));
            try out.appendSlice(self.gpa, "\"/>");
        }
        try out.appendSlice(self.gpa, "</binding></visual>");

        if (options.actions.len != 0) {
            try out.appendSlice(self.gpa, "<actions>");
            for (options.actions) |action| {
                const argument = try encodeArgument(self.gpa, id, action.key);
                defer self.gpa.free(argument);
                try out.appendSlice(self.gpa, "<action content=\"");
                try escapeInto(self.gpa, &out, action.label);
                try out.appendSlice(self.gpa, "\" arguments=\"");
                try escapeInto(self.gpa, &out, argument);
                try out.appendSlice(self.gpa, "\" activationType=\"foreground\"/>");
            }
            try out.appendSlice(self.gpa, "</actions>");
        }
        try out.appendSlice(self.gpa, "</toast>");
        return out.toOwnedSlice(self.gpa);
    }
};

/// One activation argument, decoded.
pub const Decoded = struct { id: NotificationId, key: []const u8 };

/// `<id>|<key length>|<key>`. The length prefix is what makes an action key that
/// contains the separator still route to the notification that owns it, rather
/// than to whichever notification happened to parse.
///
/// A malformed argument is refused rather than guessed at: an activation the
/// provider cannot attribute is an activation that must not be delivered to some
/// other notification.
pub fn decodeArgument(argument: []const u8) ?Decoded {
    const first = std.mem.indexOfScalar(u8, argument, '|') orelse return null;
    const second = std.mem.indexOfScalarPos(u8, argument, first + 1, '|') orelse return null;
    const id = std.fmt.parseInt(NotificationId, argument[0..first], 10) catch return null;
    const len = std.fmt.parseInt(usize, argument[first + 1 .. second], 10) catch return null;
    const rest = argument[second + 1 ..];
    if (rest.len != len) return null;
    return .{ .id = id, .key = rest };
}

pub fn encodeArgument(gpa: std.mem.Allocator, id: NotificationId, key: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "{d}|{d}|{s}", .{ id, key.len, key });
}

/// XML text escaping for attribute values and element text. The five predefined
/// entities plus a numeric escape for the control characters XML forbids
/// outright, because a body containing one is a document the platform rejects
/// and the caller deserves a real refusal rather than a mangled toast.
fn escapeInto(gpa: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    for (text) |c| {
        switch (c) {
            '&' => try out.appendSlice(gpa, "&amp;"),
            '<' => try out.appendSlice(gpa, "&lt;"),
            '>' => try out.appendSlice(gpa, "&gt;"),
            '"' => try out.appendSlice(gpa, "&quot;"),
            '\'' => try out.appendSlice(gpa, "&apos;"),
            0x09, 0x0A, 0x0D => try out.append(gpa, c),
            0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F => try out.print(gpa, "&#{d};", .{c}),
            else => try out.append(gpa, c),
        }
    }
}

/// True when this build can talk to the toast platform at all.
pub fn isApplicable() bool {
    return comptime win.is_windows;
}

test "api-w23 windows toast activation argument is self describing" {
    // An action key that contains the separator must still route to the
    // notification that owns it, which is what the length prefix is for. The
    // prefix is the key's own byte length, separator included: `open|file.txt`
    // is thirteen bytes, so the argument is `7|13|open|file.txt`.
    const decoded = decodeArgument("7|13|open|file.txt") orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(NotificationId, 7), decoded.id);
    try std.testing.expectEqualStrings("open|file.txt", decoded.key);

    const gpa = std.testing.allocator;
    const encoded = try encodeArgument(gpa, 7, "open|file.txt");
    defer gpa.free(encoded);
    try std.testing.expectEqualStrings("7|13|open|file.txt", encoded);
    // The encoder and the decoder must agree on that argument, or the shell is
    // handed a string this provider refuses and the click goes nowhere.
    const round_trip = decodeArgument(encoded) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(NotificationId, 7), round_trip.id);
    try std.testing.expectEqualStrings("open|file.txt", round_trip.key);

    // A declared length that does not describe the bytes that follow is
    // refused, so a truncated or a padded argument cannot be delivered under a
    // key the caller never offered.
    try std.testing.expect(decodeArgument("7|11|open|file.txt") == null);
    try std.testing.expect(decodeArgument("7|11|open") == null);
    try std.testing.expect(decodeArgument("7|open") == null);
    try std.testing.expect(decodeArgument("notanid|1|x") == null);
    try std.testing.expect(decodeArgument("") == null);
}

test "api-w23 windows toast xml escapes caller text" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try escapeInto(gpa, &out, "a & b < c > d \" e ' f");
    try std.testing.expectEqualStrings(
        "a &amp; b &lt; c &gt; d &quot; e &apos; f",
        out.items,
    );

    // A control character XML forbids becomes a numeric reference rather than a
    // document the platform rejects.
    var control: std.ArrayList(u8) = .empty;
    defer control.deinit(gpa);
    try escapeInto(gpa, &control, "a\x01" ++ "b");
    try std.testing.expectEqualStrings("a&#1;b", control.items);
}

test "api-w23 windows toast provider is a named refusal off windows" {
    // Windows toasts need a Start menu entry and a shell. On any other target
    // the provider claims no capability and refuses every submit by name.
    if (comptime !win.is_windows) {
        const provider = try Provider.init(std.testing.allocator, std.testing.io, .{
            .app_id = "com.7games.nogui",
        });
        defer provider.deinit();
        const handle = provider.provider();

        try std.testing.expectEqual(
            notifications.Capabilities.none,
            handle.getCapabilities(),
        );
        try std.testing.expectEqual(
            SubmitOutcome.unsupported,
            handle.submit(.{ .summary = "hello" }),
        );
        // A dismissal is named the same way: no shell to ask is not a shell
        // that said no, and a caller that reads this as a refusal waits on a
        // toast that was never shown.
        try std.testing.expectEqual(
            notifications.DismissOutcome.unsupported,
            handle.dismiss(1),
        );
        try std.testing.expect(!isApplicable());
    }
}

/// The shape `Host.notificationService` uses: build the provider, hand the
/// service its address, and keep nothing.
fn serviceWithOwnedProvider(gpa: std.mem.Allocator) !notifications.NotificationsService {
    const provider = try Provider.init(gpa, std.testing.io, .{
        .app_id = "com.7games.nogui",
    });
    errdefer provider.deinit();
    return notifications.NotificationsService.init(gpa, provider.provider());
}

test "api-w23 a toast provider outlives the frame that built it" {
    // The service holds the provider's address and releases the provider from
    // its own `deinit`, so the address it keeps has to be one that survives the
    // call that built it. A provider passed by value would leave the service
    // pointing into a frame that is already gone: every provider call would
    // read a dead frame, and the release would free a provider nobody allocated
    // while the one that was allocated leaked.
    const gpa = std.testing.allocator;
    var service = try serviceWithOwnedProvider(gpa);
    defer service.deinit();

    // Answering from the service is answering from the provider it was handed,
    // and the release that follows is the one that frees it. The testing
    // allocator fails this test if either the block or anything inside it
    // survives the service.
    try std.testing.expect(service.provider != null);
    if (comptime !win.is_windows) {
        try std.testing.expectEqual(notifications.Capabilities.none, service.getCapabilities());
        try std.testing.expectEqual(
            SubmitOutcome.unsupported,
            service.submit(.{ .summary = "hello" }, .{}, null),
        );
    }
}

/// One activation, in the shape the shim hands it to the callback.
fn pushActivation(provider: *Provider, argument: [:0]const u8) void {
    const event: Activation = .{ .argument = argument.ptr, .is_body = false };
    Provider.activationCallback(provider, &event);
}

/// A click on the toast's own body, which the shell hands over with no
/// argument at all, so there is no key in it to decode.
fn pushBodyActivation(provider: *Provider) void {
    const event: Activation = .{ .argument = null, .is_body = true };
    Provider.activationCallback(provider, &event);
}

/// The notifications one drain handed the owners, each with the notification it
/// was for: two notifications can offer the same action key, so the key alone
/// does not say which one answered.
const Routed = struct {
    ids: [4]NotificationId = @splat(0),
    keys: [4][]const u8 = @splat(""),
    count: usize = 0,

    fn onResponse(ctx: ?*anyopaque, id: NotificationId, response: notifications.Response) void {
        const self: *Routed = @ptrCast(@alignCast(ctx orelse return));
        if (response != .action) return;
        if (self.count >= self.ids.len) return;
        // The key is borrowed from the provider's ring, which is what the shared
        // service documents, and this test reads it before it pushes anything
        // else into that ring.
        self.ids[self.count] = id;
        self.keys[self.count] = response.action.key;
        self.count += 1;
    }
};

/// The action keys one drain handed the host, in the order it handed them.
const Recorded = struct {
    keys: [3][]const u8 = @splat(""),
    count: usize = 0,

    fn onResponse(ctx: ?*anyopaque, _: NotificationId, response: notifications.Response) void {
        const self: *Recorded = @ptrCast(@alignCast(ctx orelse return));
        if (self.count >= self.keys.len) return;
        // The key is borrowed from the provider's ring, which is what the
        // shared service documents, and this test reads it before it pushes
        // anything else into that ring.
        self.keys[self.count] = response.action.key;
        self.count += 1;
    }
};

test "api-w23 a queued toast activation keeps the bytes its key is in" {
    // The shell's thread writes into the ring while the host's thread drains
    // it, and the watermark is what tells the writer where the next activation
    // may go. It may only fall back to zero while nothing is queued: an
    // activation that arrived while the host was delivering another one owns
    // bytes at the old watermark, and a lower watermark would let the
    // activation after that write over them, so the host would be handed a
    // different key for a notification the user really did click.
    //
    // Which activation lands in that window is a race between two threads and
    // no test can force it, so what is stated here is the rule and the state it
    // leaves: the reclaim step with entries still queued, and then the delivery
    // a wrong watermark would corrupt.
    const gpa = std.testing.allocator;
    const provider = try Provider.init(gpa, std.testing.io, .{
        .app_id = "com.7games.nogui",
    });
    defer provider.deinit();

    pushActivation(provider, "7|5|reply");
    pushActivation(provider, "8|6|opened");
    try std.testing.expectEqual(@as(u32, 11), provider.payload_used);

    // The step a drain runs after every delivery, with the second activation
    // still queued behind the first.
    provider.reclaimPayload();
    try std.testing.expectEqual(@as(u32, 11), provider.payload_used);

    // So a third activation lands above both of them, and the host is handed the
    // three keys in the order the shell produced them.
    pushActivation(provider, "9|1|z");
    var recorded: Recorded = .{};
    var service = notifications.NotificationsService.init(gpa, null);
    defer service.deinit();
    for ([_]NotificationId{ 7, 8, 9 }) |id| {
        try service.tracked.put(id, .{
            .id = id,
            .owner = .{ .context = @ptrFromInt(1) },
            .handler = .{ .context = &recorded, .callback = Recorded.onResponse },
        });
    }
    try std.testing.expectEqual(@as(usize, 3), provider.drain(&service));
    try std.testing.expectEqual(@as(usize, 3), recorded.count);
    try std.testing.expectEqualStrings("reply", recorded.keys[0]);
    try std.testing.expectEqualStrings("opened", recorded.keys[1]);
    try std.testing.expectEqualStrings("z", recorded.keys[2]);
    // An empty ring hands the scratch back, so the next activation starts from
    // the beginning of the payload rather than growing it for the life of the
    // process.
    try std.testing.expectEqual(@as(u32, 0), provider.payload_used);
}

test "api-w23 a refused toast dismissal is not a closed notification" {
    // With no provider attached, `dismiss` has nothing to close, and that is
    // `unsupported` rather than a refusal. The two are different: unsupported
    // means there was never a notification, refused means one is still on screen
    // with its actions intact.
    var service = notifications.NotificationsService.init(std.testing.allocator, null);
    defer service.deinit();
    try std.testing.expectEqual(notifications.DismissOutcome.unsupported, service.dismiss(1));
}

test "api-w23 a queued toast activation reaches the owner through the service" {
    // The host builds a provider, hands it to a service and keeps no reference
    // to it, so the only path a user click can take to an owner is the service
    // driving that provider. A provider whose ring nobody drains holds the click
    // and never runs an owner's callback, which a host cannot tell apart from a
    // user who never clicked.
    //
    // Off Windows the provider refuses every submit, so the tracked table is
    // seeded with the ids a submit would have returned. The routing under test
    // is the service's, and it is the service's on every platform.
    const gpa = std.testing.allocator;
    const provider = try Provider.init(gpa, std.testing.io, .{
        .app_id = "com.7games.nogui",
    });
    var service = notifications.NotificationsService.init(gpa, provider.provider());
    // The service owns the provider now and releases it from here, so nothing
    // else may: a second release would free a provider the service already
    // freed.
    defer service.deinit();

    var routed: Routed = .{};
    for ([_]NotificationId{ 7, 9 }) |id| {
        try service.tracked.put(id, .{
            .id = id,
            .owner = .{ .context = @ptrFromInt(1) },
            .handler = .{ .context = &routed, .callback = Routed.onResponse },
        });
    }

    // The shell's thread copied two arguments into the provider's ring and did
    // nothing else. Both notifications offered the same action key, so only the
    // notification each argument carries says whose answer this is.
    pushActivation(provider, "7|5|reply");
    pushActivation(provider, "9|5|reply");
    try std.testing.expect(provider.hasPending());
    try std.testing.expectEqual(@as(usize, 0), routed.count);

    // Pumping the service is the whole of what the host has to do.
    try std.testing.expectEqual(@as(usize, 2), try service.pump(0));
    try std.testing.expectEqual(@as(usize, 2), routed.count);
    try std.testing.expectEqual(@as(NotificationId, 7), routed.ids[0]);
    try std.testing.expectEqualStrings("reply", routed.keys[0]);
    try std.testing.expectEqual(@as(NotificationId, 9), routed.ids[1]);
    try std.testing.expectEqualStrings("reply", routed.keys[1]);
    // The ring is empty and the payload scratch is home, so the next activation
    // starts at the beginning rather than growing for the life of the process.
    try std.testing.expect(!provider.hasPending());
    try std.testing.expectEqual(@as(u32, 0), provider.payload_used);

    // An empty ring hands over nothing rather than reporting an answer twice.
    try std.testing.expectEqual(@as(usize, 0), try service.pump(0));
    try std.testing.expectEqual(@as(usize, 2), routed.count);

    // An argument whose declared length does not describe the bytes that follow
    // names no notification, so it reaches no owner rather than one it never
    // belonged to. The provider hands it over; the service is what refuses it,
    // which is why the two counts differ here.
    pushActivation(provider, "7|11|reply");
    try std.testing.expectEqual(@as(usize, 1), try service.pump(0));
    try std.testing.expectEqual(@as(usize, 2), routed.count);

    // A body click carries no argument, so it names no notification either.
    pushBodyActivation(provider);
    try std.testing.expectEqual(@as(usize, 1), try service.pump(0));
    try std.testing.expectEqual(@as(usize, 2), routed.count);
}

test "api-w23 a second toast provider cannot take the first one's activation" {
    // COM keeps one class object, cookie, callback and context for an activation
    // in a process, so two providers cannot both have one. The one that does not
    // get it must be told so, and must leave the holder completely alone: a
    // provider that overwrote the registration would leave the first claiming
    // `actions` with no path to any click, and both providers silently deaf.
    //
    // What this states is the lease the host layer owns, which is the same on
    // every target; the COM half of the registration needs a shell, and the shim
    // refuses a conflicting registration of its own account for that reason.
    const gpa = std.testing.allocator;
    const cls_id = "{6E1B2C7A-0000-4000-8000-00000000ABCD}";

    const holder = try Provider.init(gpa, std.testing.io, .{
        .app_id = "com.7games.nogui",
        .activator_cls_id = cls_id,
    });
    // A failed assertion below still has to give the registration back.
    errdefer holder.deinit();

    const contender = try Provider.init(gpa, std.testing.io, .{
        .app_id = "com.7games.nogui",
        .activator_cls_id = cls_id,
    });

    // One provider holds it and the other was told it cannot have it. A provider
    // built without a class id never asked, so it holds nothing and says so.
    try std.testing.expectEqual(Activator.ready, holder.activatorOf());
    try std.testing.expectEqual(Activator.already_registered, contender.activatorOf());
    // Refused means no actions claimed, which is what a caller needs to know
    // before it waits for a click this provider will never be handed. What else
    // the platform can show is a separate answer, and is not this one.
    try std.testing.expect(!contender.provider().getCapabilities().actions);

    // The holder is untouched, and its ring is the one the shell's callback
    // writes into: the loser took nothing.
    pushActivation(holder, "1|5|reply");
    try std.testing.expect(holder.hasPending());
    try std.testing.expect(!contender.hasPending());
    try std.testing.expectEqual(@as(u32, 0), contender.droppedActivations());

    // The loser going away releases a lease it never held, so the holder keeps
    // it. A release that cleared the registration would leave the holder
    // claiming an action the shell can no longer reach.
    contender.deinit();
    try std.testing.expectEqual(Activator.ready, holder.activatorOf());
    pushActivation(holder, "2|6|opened");
    try std.testing.expect(holder.hasPending());

    // A provider that asked for nothing releases nothing: the registration the
    // holder took is still the holder's afterwards.
    const idle = try Provider.init(gpa, std.testing.io, .{ .app_id = "com.7games.nogui" });
    errdefer idle.deinit();
    try std.testing.expectEqual(Activator.none, idle.activatorOf());
    idle.deinit();
    try std.testing.expectEqual(Activator.ready, holder.activatorOf());

    // The holder gives it back, and the next provider to ask takes it, so a
    // released registration is not a permanent loss.
    holder.deinit();
    const next = try Provider.init(gpa, std.testing.io, .{
        .app_id = "com.7games.nogui",
        .activator_cls_id = cls_id,
    });
    defer next.deinit();
    try std.testing.expectEqual(Activator.ready, next.activatorOf());
}

/// Enough bytes for any key these tests copy out of the ring. The keys are
/// named here and nowhere longer, so a copy that lost its tail is visible as a
/// short string rather than passing on a prefix.
const borrowed_key_capacity: usize = 32;

/// One owner's answers, each copied out of the ring at the moment it was
/// routed.
///
/// A response key is borrowed from the provider's payload ring, and what the
/// tests below are about is what that ring does to bytes a delivery is still
/// holding. An owner that re-reads the ring after the drain would be reading
/// bytes whose contents are exactly what is in question, so each owner keeps
/// its own copy instead, taken while the borrow is live.
const Copied = struct {
    ids: [3]NotificationId = @splat(0),
    keys: [3][borrowed_key_capacity]u8 = .{ @splat(0), @splat(0), @splat(0) },
    lens: [3]usize = @splat(0),
    count: usize = 0,

    fn onResponse(ctx: ?*anyopaque, id: NotificationId, response: notifications.Response) void {
        const self: *Copied = @ptrCast(@alignCast(ctx orelse return));
        if (response != .action) return;
        if (self.count >= self.ids.len) return;
        const key = response.action.key;
        const n = @min(key.len, borrowed_key_capacity);
        @memcpy(self.keys[self.count][0..n], key[0..n]);
        self.ids[self.count] = id;
        self.lens[self.count] = n;
        self.count += 1;
    }
};

/// One owner's completions, counted rather than collected, because what is at
/// stake across a shutdown is how many times the owner was told: once, with
/// the close the shutdown reports, and never again for anything that arrives
/// afterwards.
const Completed = struct {
    count: usize = 0,
    reason: notifications.CloseReason = .undefined,

    fn onResponse(ctx: ?*anyopaque, _: NotificationId, response: notifications.Response) void {
        const self: *Completed = @ptrCast(@alignCast(ctx orelse return));
        self.count += 1;
        if (response == .closed) self.reason = response.closed.reason;
    }
};

test "api-w23 a toast activation after shutdown reaches nothing" {
    // The service marks itself terminal, disconnects the provider and hands
    // every tracked notification its one completion. It does not release the
    // provider: the records the shell's thread copies into are still there and
    // still valid, and it is `deinit` that frees them, later.
    //
    // A click that was already on its way when the service shut down therefore
    // lands on a provider that cannot reach anything. There is no owner left
    // waiting, no path from the ring to a callback, and no notification the
    // platform would ever deliver again. The activation has nothing to do, so
    // it takes no ring slot, latches nothing pending, consumes no payload byte
    // and is not counted as lost: an activation this provider was never going
    // to hand to anyone is not a user click that went somewhere it could have
    // been delivered.
    const gpa = std.testing.allocator;
    const provider = try Provider.init(gpa, std.testing.io, .{
        .app_id = "com.7games.nogui",
    });
    var service = notifications.NotificationsService.init(gpa, provider.provider());
    // The service owns the provider from here and releases it at the end of the
    // test, which is what leaves the provider's storage valid across the whole
    // of it. No handler here releases anything.
    defer service.deinit();

    var completed: Completed = .{};
    try service.tracked.put(7, .{
        .id = 7,
        .owner = .{ .context = @ptrFromInt(1) },
        .handler = .{ .context = &completed, .callback = Completed.onResponse },
    });

    service.shutdown();
    try std.testing.expectEqual(@as(usize, 1), completed.count);
    try std.testing.expectEqual(
        notifications.CloseReason.closed_by_call,
        completed.reason,
    );

    // The shell's thread copies one argument into the provider's ring and does
    // nothing else. The provider is disconnected, so the copy is refused
    // before any of it happens.
    pushActivation(provider, "7|5|reply");

    try std.testing.expectEqual(@as(u32, 0), provider.queue_len);
    try std.testing.expect(!provider.hasPending());
    try std.testing.expectEqual(@as(u32, 0), provider.payload_used);
    try std.testing.expectEqual(@as(u32, 0), provider.droppedActivations());

    // A host that pumps again on the next frame is told there was nothing, and
    // the owner is not told anything a second time: a click that arrived after
    // its notification was already completed is not an answer to a question
    // that is still open.
    try std.testing.expectEqual(@as(usize, 0), try service.pump(0));
    try std.testing.expectEqual(@as(usize, 1), completed.count);

    // Shutting down again is not a second completion either.
    service.shutdown();
    try std.testing.expectEqual(@as(usize, 1), completed.count);
}

/// The owner whose handler is already on the stack when the next two clicks
/// arrive.
///
/// It keeps the key it was handed instead of copying it, because that is what
/// the shared contract tells a caller to do with a borrowed key: the bytes stay
/// valid for the whole of the callback that received them, and reading them
/// again at the end of that callback is reading them inside the borrow, not
/// after it.
const Nested = struct {
    provider: *Provider,
    service: *notifications.NotificationsService,
    /// Which notification this answer was for. Two notifications can offer the
    /// same key, so the key alone does not say whose answer this is.
    id: NotificationId = 0,
    calls: usize = 0,
    /// The key this handler received, still pointing into the provider's ring.
    borrowed: []const u8 = "",
    /// What that key read as on the second read, copied out inside the callback
    /// where the borrow is still live.
    seen: [borrowed_key_capacity]u8 = @splat(0),
    seen_len: usize = 0,
    /// What the drain this handler asked for delivered.
    inner_delivered: usize = 0,

    fn onResponse(ctx: ?*anyopaque, id: NotificationId, response: notifications.Response) void {
        const self: *Nested = @ptrCast(@alignCast(ctx orelse return));
        if (response != .action) return;
        self.id = id;
        self.calls += 1;
        // A second answer for this notification would reenter the whole
        // sequence; it is counted and the recursion stops there.
        if (self.calls > 1) return;

        self.borrowed = response.action.key;

        // A host pumping once per frame can be asked to pump again from inside
        // the callback this drain is already running, and the shell's thread
        // is not the only thing that writes the ring while that happens.
        pushActivation(self.provider, "8|6|second");
        self.inner_delivered = self.service.pump(0) catch |err|
            std.debug.panic("nested toast drain failed: {s}", .{@errorName(err)});

        // And a click can land after the nested drain has walked the ring empty
        // and handed the scratch back.
        pushActivation(self.provider, "9|5|third");

        // The key is read once more here, still inside the callback that
        // received it. That is the whole of what the borrow promises, and it
        // has to hold through everything the callback did in between: an
        // activation the host never delivered must not change the key the host
        // is holding.
        const again = self.borrowed;
        self.seen_len = @min(again.len, self.seen.len);
        @memcpy(self.seen[0..self.seen_len], again[0..self.seen_len]);
    }
};

test "api-w23 a nested toast drain keeps the key an outer handler still holds" {
    // A key the service is handed is borrowed from the provider's payload ring,
    // and it is valid for the whole of the callback that received it. That
    // callback is not a leaf: it can push another activation, drive another
    // drain, and have a further activation arrive, all before it is finished.
    //
    // The nested drain empties the ring, so the reclaim step after it sees an
    // empty ring and hands the scratch back to zero. If that is taken as
    // permission to reuse the bytes, the next activation is written at offset
    // zero, which is where the outer handler's key is, and the host reads back
    // a key for a notification the user never clicked. An empty ring is not the
    // same as an unheld ring.
    const gpa = std.testing.allocator;
    const provider = try Provider.init(gpa, std.testing.io, .{
        .app_id = "com.7games.nogui",
    });
    var service = notifications.NotificationsService.init(gpa, provider.provider());
    defer service.deinit();

    // Three notifications, three distinct ids and three distinct keys, so an
    // answer that names the wrong one is visible rather than plausible. Two of
    // the clicks arrive while the first notification's handler is running, and
    // both belong to a notification other than the one being answered.
    var inner: Copied = .{};
    var tail: Copied = .{};
    var outer: Nested = .{ .provider = provider, .service = &service };
    try service.tracked.put(7, .{
        .id = 7,
        .owner = .{ .context = @ptrFromInt(1) },
        .handler = .{ .context = &outer, .callback = Nested.onResponse },
    });
    try service.tracked.put(8, .{
        .id = 8,
        .owner = .{ .context = @ptrFromInt(1) },
        .handler = .{ .context = &inner, .callback = Copied.onResponse },
    });
    try service.tracked.put(9, .{
        .id = 9,
        .owner = .{ .context = @ptrFromInt(1) },
        .handler = .{ .context = &tail, .callback = Copied.onResponse },
    });

    // One click, and one drain. Everything after that happens inside the owner
    // handler the drain is running.
    pushActivation(provider, "7|9|outer-key");
    // The outer drain keeps walking after its handler returns, so it delivers
    // this notification's own answer and the click that arrived late. The one
    // the nested drain delivered is counted by that drain, on its own.
    try std.testing.expectEqual(@as(usize, 2), try service.pump(0));

    // The owner whose handler ran was answered exactly once, for its own
    // notification.
    try std.testing.expectEqual(@as(usize, 1), outer.calls);
    try std.testing.expectEqual(@as(NotificationId, 7), outer.id);

    // And the key it is still holding is the key it was sent, after a nested
    // drain and a further activation happened in between.
    try std.testing.expectEqualStrings(
        "outer-key",
        outer.seen[0..outer.seen_len],
    );

    // The click that was queued before the nested drain reached its own owner,
    // with its own key, rather than being folded into the answer that was
    // already being delivered.
    try std.testing.expectEqual(@as(usize, 1), outer.inner_delivered);
    try std.testing.expectEqual(@as(usize, 1), inner.count);
    try std.testing.expectEqual(@as(NotificationId, 8), inner.ids[0]);
    try std.testing.expectEqualStrings("second", inner.keys[0][0..inner.lens[0]]);

    // The click that arrived after the nested drain is routed on the way out, to
    // its own notification and with its own key.
    try std.testing.expectEqual(@as(usize, 1), tail.count);
    try std.testing.expectEqual(@as(NotificationId, 9), tail.ids[0]);
    try std.testing.expectEqualStrings("third", tail.keys[0][0..tail.lens[0]]);
}
