//! Native asynchronous file, path and prompt dialogs with parent window lifetime.
//! Cancellation is a distinct outcome, never an empty successful file list.
//! Every pending native callback holds a lease, so tearing the manager down or
//! closing the parent window can never leave a dangling `*DialogManager`.
const std = @import("std");
const sdl3 = @import("sdl3");
const builtin = @import("builtin");
const portal = @import("linux/portal.zig");

/// How `Filter.pattern` is read.
///
/// The native dialogs and the xdg-desktop-portal FileChooser do not read the
/// same string the same way. SDL's own `SDL_DialogFileFilter.pattern`, which
/// every native backend reaches through SDL, is a `;` separated extension
/// list; the portal matches each of its patterns against the whole file name.
/// A filter therefore says which one it is written for, and the host
/// translates it instead of forwarding a string the far end reads as
/// something else.
pub const FilterMatch = enum {
    /// `;` separates extensions without a leading dot: `txt;md` answers a
    /// chooser as every file whose name ends in `.txt` or `.md`. This is the
    /// mode SDL, and through it the macOS and Windows panels, read, so it is
    /// the default and every filter written before the mode existed keeps the
    /// meaning it had.
    extension,
    /// `;` separates whole-name globs: `*.txt;*.md` answers a chooser the same
    /// way `txt;md` does in `extension`, because that is the shape the portal
    /// matches. `*` is the only metacharacter.
    glob,
};

/// One file dialog filter. `pattern` is read in `match` mode, and `*` on its
/// own means every file in either mode.
pub const Filter = struct {
    name: []const u8,
    pattern: []const u8,
    match: FilterMatch = .extension,

    /// Whether this filter can select anything at all. A pattern that no
    /// chooser answers is refused here, before a native dialog opens, rather
    /// than accepted and then shown as an empty view.
    pub fn validate(self: Filter) bool {
        if (self.name.len == 0 or self.pattern.len == 0) return false;
        if (std.mem.indexOfScalar(u8, self.pattern, 0) != null) return false;
        var parts = std.mem.splitScalar(u8, self.pattern, ';');
        while (parts.next()) |part| {
            if (part.len == 0) return false;
            switch (self.match) {
                .extension => {
                    if (std.mem.eql(u8, part, "*")) continue;
                    for (part) |byte| {
                        const allowed = std.ascii.isAlphanumeric(byte) or byte == '-' or
                            byte == '_' or byte == '.';
                        if (!allowed) return false;
                    }
                },
                .glob => {
                    // A part with no `*` is an exact whole-name match. That is
                    // the shape that emptied a real chooser: `txt` asks for a
                    // file called `txt`, and no directory holds one. It is
                    // refused here rather than sent and matched against
                    // nothing.
                    if (std.mem.indexOfScalar(u8, part, '*') == null) return false;
                    for (part) |byte| {
                        // `?` and the bracket forms are refused on purpose. A
                        // GTK chooser honours them and the native panels do
                        // not, so one pattern would select on one host and
                        // match nothing on another.
                        const allowed = std.ascii.isAlphanumeric(byte) or byte == '-' or
                            byte == '_' or byte == '.' or byte == ' ' or byte == '*';
                        if (!allowed) return false;
                    }
                },
            }
        }
        return true;
    }
};

pub const FileMode = enum {
    open_file,
    open_multiple_files,
    open_folder,
    save_file,
};

pub const FileOptions = struct {
    mode: FileMode = .open_file,
    title: ?[]const u8 = null,
    /// A filesystem path the dialog opens in.
    default_location: ?[]const u8 = null,
    /// Empty by default, and an empty list opens the dialog unfiltered rather
    /// than being refused. Every entry is read in its own `Filter.match`
    /// mode, so one request can offer an extension list to SDL and a glob to
    /// the portal side by side.
    ///
    /// Ignored by the native folder dialog, which takes no filters.
    filters: []const Filter = &.{},
    /// The dialog is modal for this window. Closing it resolves the request.
    parent_window: ?sdl3.video.WindowId = null,
    accept_label: ?[]const u8 = null,
    /// The Linux portal, SDL's cocoa and android file dialogs and SDL's own
    /// portal dialog have no cancel label, so a request that sets this is
    /// refused as `unsupported` on those paths instead of being sent a
    /// property the far end would accept and ignore. A backend that does
    /// read it still shows the label.
    cancel_label: ?[]const u8 = null,
};

/// A successful, owned selection. Paths are copies that outlive the native
/// callback frame; the receiver releases them with `deinit`.
pub const FileSelection = struct {
    allocator: std.mem.Allocator,
    paths: []const []const u8,
    /// Index into `FileOptions.filters`, when the platform reports one.
    filter_index: ?usize = null,

    pub const Error = error{EmptySelection} || std.mem.Allocator.Error;

    /// Copy borrowed paths into owned storage. Rejects an empty list, because a
    /// user cancellation is reported as `cancelled` and never as success.
    pub fn init(
        allocator: std.mem.Allocator,
        paths: []const []const u8,
        filter_index: ?usize,
    ) Error!FileSelection {
        if (paths.len == 0) return error.EmptySelection;
        const owned: []const []const u8 = try allocator.alloc([]u8, paths.len);
        errdefer allocator.free(owned);
        var filled: usize = 0;
        errdefer for (owned[0..filled]) |path| allocator.free(path);
        for (paths, 0..) |path, index| {
            @constCast(owned)[index] = try allocator.dupe(u8, path);
            filled += 1;
        }
        return .{ .allocator = allocator, .paths = owned, .filter_index = filter_index };
    }

    /// Copy a native list of owned C strings exactly once.
    ///
    /// SDL hands over a `const char * const *`, and the binding counts that
    /// array up to its own null slot before it slices it, so the slice names
    /// exactly the paths a person chose: two chosen paths arrive as two
    /// slots. The null that ends the C array is therefore never a slot here
    /// and never a path, and the element type is a C string pointer rather
    /// than an optional, so no slot can spell one.
    pub fn fromNativeList(
        allocator: std.mem.Allocator,
        list: []const [*:0]const u8,
        filter_index: ?usize,
    ) Error!FileSelection {
        if (list.len == 0) return error.EmptySelection;
        const owned: []const []const u8 = try allocator.alloc([]u8, list.len);
        errdefer allocator.free(owned);
        var filled: usize = 0;
        errdefer for (owned[0..filled]) |path| allocator.free(path);
        for (list, 0..) |entry, index| {
            @constCast(owned)[index] = try allocator.dupe(u8, std.mem.span(entry));
            filled += 1;
        }
        return .{ .allocator = allocator, .paths = owned, .filter_index = filter_index };
    }

    pub fn deinit(self: *FileSelection) void {
        for (self.paths) |path| self.allocator.free(path);
        self.allocator.free(self.paths);
        self.* = undefined;
    }
};

/// Typed failure reasons. A provider that never runs is not a success.
pub const Failure = enum {
    native_error,
    out_of_memory,
};

pub const FileOutcome = union(enum) {
    /// Owned by the receiver; release with `deinitFileOutcome`.
    selected: FileSelection,
    /// The user dismissed the dialog. Never a successful empty list.
    cancelled,
    /// Another action took the dialog over, so no one chose.
    aborted,
    /// The platform reported success and named no path. A person accepted
    /// this dialog, so it is neither a cancellation nor a failure.
    empty_selection,
    /// The parent window closed before the dialog completed.
    parent_closed,
    /// This host cannot service the request as asked: no provider for it
    /// exists, the platform has no documented option the request needs, or
    /// the host installed no worker for a request that blocks on a person.
    /// Not a failed request, and never a cancellation.
    unsupported,
    failed: Failure,
};

/// Release an outcome the receiver chose not to consume.
pub fn deinitFileOutcome(outcome: *FileOutcome) void {
    switch (outcome.*) {
        .selected => |*selection| selection.deinit(),
        else => {},
    }
}

pub const MessageSeverity = enum { information, warning, critical };

pub const MessageButton = struct {
    id: i32,
    text: []const u8,
    is_default: bool = false,
    is_escape: bool = false,
};

pub const MessageOptions = struct {
    title: []const u8,
    message: []const u8,
    severity: MessageSeverity = .information,
    /// An empty list asks the platform for its own single confirmation button.
    buttons: []const MessageButton = &.{},
    parent_window: ?sdl3.video.WindowId = null,
};

pub const MessageOutcome = union(enum) {
    pressed: i32,
    cancelled,
    parent_closed,
    failed: Failure,
};

/// Explicit point-of-risk gate. A native popup or external launch is a
/// user-visible external action and must be approved by the caller.
pub const PointOfRiskApproval = struct {
    confirmed: bool = false,
};

pub const FileCallback = struct {
    context: ?*anyopaque = null,
    /// Receives ownership of the outcome.
    callback: *const fn (?*anyopaque, FileOutcome) void,
};

pub const MessageCallback = struct {
    context: ?*anyopaque = null,
    callback: *const fn (?*anyopaque, MessageOutcome) void,
};

/// Pluggable provider. The allocator is the manager's, so a provider builds
/// owned outcomes with it. A provider either delivers one outcome or returns
/// an error, never both.
/// Custom providers invoke completion on the host UI thread.
pub const DialogProvider = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        showFileDialog: *const fn (
            std.mem.Allocator,
            *anyopaque,
            FileOptions,
            FileCallback,
        ) anyerror!void,
        showMessageDialog: *const fn (
            std.mem.Allocator,
            *anyopaque,
            MessageOptions,
            MessageCallback,
        ) anyerror!void,
    };

    pub fn showFile(
        self: DialogProvider,
        allocator: std.mem.Allocator,
        options: FileOptions,
        callback: FileCallback,
    ) !void {
        return self.vtable.showFileDialog(allocator, self.context, options, callback);
    }

    pub fn showMessage(
        self: DialogProvider,
        allocator: std.mem.Allocator,
        options: MessageOptions,
        callback: MessageCallback,
    ) !void {
        return self.vtable.showMessageDialog(allocator, self.context, options, callback);
    }
};

/// A host-owned worker for a request that blocks on a person. The library
/// starts no thread of its own: the host installs the worker it already runs
/// its work on, and a manager without one reports `unsupported` instead of a
/// private runtime nothing can cancel, bound or observe.
pub const Worker = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Start `work(payload)` away from the calling thread and return. The
        /// worker keeps `payload` alive until `work` returns. Returning an
        /// error means the work never started.
        run: *const fn (context: *anyopaque, work: *const fn (*anyopaque) void, payload: *anyopaque) anyerror!void,
    };

    pub fn run(
        self: Worker,
        work: *const fn (*anyopaque) void,
        payload: *anyopaque,
    ) !void {
        return self.vtable.run(self.context, work, payload);
    }
};

/// A per-request record shared by the manager and the native callback. Two
/// references are held at launch: one by the manager, one by the callback side.
/// The record survives until both are released, so a late native callback never
/// dereferences a destroyed manager.
const Lease = struct {
    allocator: std.mem.Allocator,
    refs: std.atomic.Value(usize) = .init(2),
    /// Only the host UI thread reads or clears this pointer. Native callbacks
    /// marshal through SDL's main-thread queue before resolving a lease.
    owner: ?*DialogManager,
    id: u64,
    parent_window: ?sdl3.video.WindowId,
    completion: Completion,
    /// Raised when the manager resolves this request itself, so a provider
    /// parked on a native dialog stops instead of holding it open for a
    /// person who is gone. Only the manager writes it, and only while it
    /// still holds its own reference, so a provider reading it is always
    /// reading live storage.
    cancelled: std.atomic.Value(bool) = .init(false),

    const Completion = union(enum) {
        file: FileCallback,
        message: MessageCallback,
    };

    fn release(self: *Lease) void {
        const prior = self.refs.fetchSub(1, .acq_rel);
        std.debug.assert(prior > 0);
        if (prior == 1) self.allocator.destroy(self);
    }
};

fn bridgeFile(context: ?*anyopaque, outcome: FileOutcome) void {
    const lease: *Lease = @ptrCast(@alignCast(context.?));
    if (lease.owner) |manager| {
        manager.deliverFile(lease, outcome);
    } else {
        var mut_outcome = outcome;
        deinitFileOutcome(&mut_outcome);
    }
    lease.release();
}

fn bridgeMessage(context: ?*anyopaque, outcome: MessageOutcome) void {
    const lease: *Lease = @ptrCast(@alignCast(context.?));
    if (lease.owner) |manager| manager.deliverMessage(lease, outcome);
    lease.release();
}

/// Tracks in-flight dialogs and keeps native callbacks safe across teardown.
pub const DialogManager = struct {
    allocator: std.mem.Allocator,
    next_id: u64 = 1,
    leases: std.ArrayListUnmanaged(*Lease) = .empty,
    provider: ?DialogProvider = null,
    /// A provider that must block on a person runs here. The library starts
    /// no thread of its own: a host installs the worker it already owns, and
    /// a manager without one reports `unsupported` rather than running a
    /// private worker nothing can cancel or observe.
    worker: ?Worker = null,

    pub const Error = error{
        ActionNotApproved,
        InvalidFilter,
        ParentWindowUnavailable,
    } || std.mem.Allocator.Error;

    pub fn init(allocator: std.mem.Allocator) DialogManager {
        return .{ .allocator = allocator };
    }

    pub fn setWorker(self: *DialogManager, worker: ?Worker) void {
        self.worker = worker;
    }

    /// Detaches every pending request and tells the ones still running to
    /// stop. A later native callback finds no owner and frees its own outcome
    /// instead of touching this manager.
    pub fn deinit(self: *DialogManager) void {
        for (self.leases.items) |lease| {
            lease.owner = null;
            lease.cancelled.store(true, .release);
            lease.release();
        }
        self.leases.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn setProvider(self: *DialogManager, provider: ?DialogProvider) void {
        self.provider = provider;
    }

    pub fn pendingCount(self: *const DialogManager) usize {
        return self.leases.items.len;
    }

    /// Resolve every request parented to `window_id` as `parent_closed` and
    /// forget it. A request that is still running is told to stop, so a
    /// provider able to dismiss its native dialog does. A later completion
    /// for that request is dropped, so application state stays unchanged.
    pub fn onWindowClosed(self: *DialogManager, window_id: sdl3.video.WindowId) void {
        var index: usize = 0;
        while (index < self.leases.items.len) {
            const lease = self.leases.items[index];
            const parented = lease.parent_window != null and lease.parent_window.? == window_id;
            if (!parented) {
                index += 1;
                continue;
            }
            const completion = lease.completion;
            lease.cancelled.store(true, .release);
            _ = self.detach(lease);
            switch (completion) {
                .file => |callback| callback.callback(callback.context, .parent_closed),
                .message => |callback| callback.callback(callback.context, .parent_closed),
            }
        }
    }

    pub fn showFile(
        self: *DialogManager,
        options: FileOptions,
        approval: PointOfRiskApproval,
        callback: FileCallback,
    ) !void {
        if (!approval.confirmed) return error.ActionNotApproved;
        for (options.filters) |filter| {
            if (!filter.validate()) return error.InvalidFilter;
        }
        const lease = try self.addLease(options.parent_window, .{ .file = callback });
        const id = lease.id;
        if (self.provider) |provider| {
            provider.showFile(self.allocator, options, .{
                .context = lease,
                .callback = bridgeFile,
            }) catch |err| {
                self.abandonLease(id);
                return err;
            };
            return;
        }
        launchSdlFile(self.allocator, options, lease) catch |err| {
            self.abandonLease(id);
            return err;
        };
    }

    /// SDL message boxes are modal and block, so the outcome is delivered
    /// before this call returns. The callback shape is kept for symmetry.
    pub fn showMessage(
        self: *DialogManager,
        options: MessageOptions,
        approval: PointOfRiskApproval,
        callback: MessageCallback,
    ) !void {
        if (!approval.confirmed) return error.ActionNotApproved;
        const lease = try self.addLease(options.parent_window, .{ .message = callback });
        const id = lease.id;
        if (self.provider) |provider| {
            provider.showMessage(self.allocator, options, .{
                .context = lease,
                .callback = bridgeMessage,
            }) catch |err| {
                self.abandonLease(id);
                return err;
            };
            return;
        }
        showSdlMessage(self.allocator, options, lease) catch |err| {
            self.abandonLease(id);
            return err;
        };
    }

    fn addLease(
        self: *DialogManager,
        parent_window: ?sdl3.video.WindowId,
        completion: Lease.Completion,
    ) std.mem.Allocator.Error!*Lease {
        const lease = try self.allocator.create(Lease);
        errdefer self.allocator.destroy(lease);
        const id = self.nextId();
        lease.* = .{
            .allocator = self.allocator,
            .owner = self,
            .id = id,
            .parent_window = parent_window,
            .completion = completion,
        };
        try self.leases.append(self.allocator, lease);
        return lease;
    }

    fn nextId(self: *DialogManager) u64 {
        const id = self.next_id;
        self.next_id +%= 1;
        return id;
    }

    /// Drop the manager reference. Returns false when the request was already
    /// resolved, in which case the lease must not be touched again.
    fn detach(self: *DialogManager, lease: *Lease) bool {
        for (self.leases.items, 0..) |item, index| {
            if (item.id != lease.id) continue;
            _ = self.leases.swapRemove(index);
            lease.owner = null;
            lease.release();
            return true;
        }
        return false;
    }

    /// Release both references after a launch that will never call back.
    /// A provider may invoke the callback synchronously, so look up by the
    /// copied ID rather than dereferencing a possibly freed lease.
    fn abandonLease(self: *DialogManager, id: u64) void {
        for (self.leases.items) |lease| {
            if (lease.id != id) continue;
            _ = self.detach(lease);
            lease.release();
            return;
        }
    }

    fn deliverFile(self: *DialogManager, lease: *Lease, outcome: FileOutcome) void {
        const completion = lease.completion;
        if (!self.detach(lease)) {
            var mut_outcome = outcome;
            deinitFileOutcome(&mut_outcome);
            return;
        }
        switch (completion) {
            .file => |callback| callback.callback(callback.context, outcome),
            .message => {
                var mut_outcome = outcome;
                deinitFileOutcome(&mut_outcome);
            },
        }
    }

    fn deliverMessage(self: *DialogManager, lease: *Lease, outcome: MessageOutcome) void {
        const completion = lease.completion;
        if (!self.detach(lease)) return;
        switch (completion) {
            .message => |callback| callback.callback(callback.context, outcome),
            .file => {},
        }
    }
};

fn nativeWindow(id: sdl3.video.WindowId) DialogManager.Error!sdl3.video.Window {
    const raw = sdl3.c.SDL_GetWindowFromID(id) orelse return error.ParentWindowUnavailable;
    return .{ .value = raw };
}

/// Only the callback hand-off uses this lock; no I/O runs while it is held.
const SpinLock = struct {
    flag: std.atomic.Value(bool) = .init(false),

    fn lock(self: *SpinLock) void {
        while (self.flag.cmpxchgStrong(false, true, .acquire, .monotonic) != null)
            std.atomic.spinLoopHint();
    }

    fn unlock(self: *SpinLock) void {
        self.flag.store(false, .release);
    }
};

/// Everything SDL must keep alive until the native callback returns. A native
/// callback can arrive before the launch function returns and on another
/// thread. The mutex transfers the result only after properties exist.
const SdlFileCall = struct {
    allocator: std.mem.Allocator,
    lease: *Lease,
    arena: std.heap.ArenaAllocator,
    mutex: SpinLock = .{},
    properties: ?sdl3.properties.Group = null,
    outcome: ?FileOutcome = null,
    launched: bool = false,

    /// Releases the call's own resources and poisons the record. The record
    /// itself belongs to `allocator`, and only a caller that still holds a
    /// live receiver can free it, so the callers below read the allocator out
    /// first and `destroy` the record once this returns.
    fn deinit(self: *SdlFileCall) void {
        if (self.properties) |*group| group.deinit();
        self.arena.deinit();
        self.* = undefined;
    }

    fn finishOnMain(self: *SdlFileCall) void {
        const lease = self.lease;
        const outcome = self.outcome.?;
        const allocator = self.allocator;
        self.deinit();
        allocator.destroy(self);
        bridgeFile(lease, outcome);
    }

    fn finishCallback(self: ?*SdlFileCall) void {
        self.?.finishOnMain();
    }

    fn schedule(self: *SdlFileCall) void {
        if (sdl3.isMainThread()) {
            self.finishOnMain();
            return;
        }
        sdl3.runOnMainThread(SdlFileCall, finishCallback, self, false) catch {
            // SDL stopped before dispatch. Drop the native half and result;
            // the manager releases its half during teardown.
            var outcome = self.outcome.?;
            const lease = self.lease;
            const allocator = self.allocator;
            self.deinit();
            allocator.destroy(self);
            deinitFileOutcome(&outcome);
            lease.release();
        };
    }
};

/// Turn one SDL file callback into one outcome, following the contract of
/// `SDL_DialogFileCallback`: a `NULL` list is a native error, a non-`NULL`
/// list whose first entry is `NULL` reports that nobody chose anything, and a
/// non-`NULL` list with a first entry carries one path or more. The wrapper
/// turns the `NULL` list into `failed`, so `failed` is the only shape an error
/// takes and `list == null` is the "no choice" shape, never a second failure.
/// Every SDL backend passes a pointer to `NULL` for a dismissed dialog, so a
/// cancellation stays `cancelled` and never becomes `native_error`. A dialog
/// a person accepted but that named no path is not expressible here: SDL
/// collapses it into that same shape, so only a provider whose reply carries
/// the response code, such as the portal, can report `empty_selection`.
///
/// The list reaches us already counted: the binding stops at SDL's own null
/// slot, so the slice holds the chosen paths and nothing after them. A list
/// that names no path is the dismissal whether it arrives as no list at all
/// or as one with nothing in it, and neither is a success with zero paths.
fn sdlFileCallback(
    call: ?*SdlFileCall,
    list: ?[]const [*:0]const u8,
    filter: ?usize,
    failed: bool,
) void {
    const self = call.?;
    const allocator = self.allocator;
    // SAFETY: the if/else chain below assigns every field of `outcome` on
    // each of its three paths, so no field is read before it is written.
    var outcome: FileOutcome = undefined;
    if (failed) {
        outcome = .{ .failed = .native_error };
    } else if (list == null or list.?.len == 0) {
        outcome = .cancelled;
    } else {
        outcome = if (FileSelection.fromNativeList(allocator, list.?, filter)) |selection|
            .{ .selected = selection }
        else |err|
            .{ .failed = switch (err) {
                error.EmptySelection => .native_error,
                error.OutOfMemory => .out_of_memory,
            } };
    }
    self.mutex.lock();
    self.outcome = outcome;
    const launched = self.launched;
    self.mutex.unlock();
    if (launched) self.schedule();
}

/// The refusal one SDL-path file request gets before any dialog opens, or null
/// when the running SDL file dialog can express every part of it.
///
/// Only `cancel_label` is such a request, and only on the backends that never
/// read it. Every answer below comes from that backend's own source:
///
///   * `cocoa`: DROPPED. `SDL_cocoadialog.m`'s
///     `SDL_SYS_ShowFileDialogWithProperties` reads exactly seven file-dialog
///     properties - WINDOW, FILTERS, NFILTERS, MANY, LOCATION, TITLE and
///     ACCEPT - and `SDL_PROP_FILE_DIALOG_CANCEL_STRING` appears nowhere in
///     the file, so a label handed to that panel is read by nobody.
///   * `android`: DROPPED. `SDL_androiddialog.c` reads FILTERS, NFILTERS and
///     MANY, and no cancel property.
///   * `windows`: READ. `SDL_windowsdialog.c` reads the cancel property and
///     calls `SetCancelButtonLabel` on the dialog.
///   * `haiku`: READ. `SDL_haikudialog.cc` reads the cancel property and calls
///     `SetButtonLabel` on the panel's cancel button.
///
/// `x11` and `wayland` reach SDL's unix dialog, which picks between its own
/// portal dialog and zenity at run time, and only `file_dialog_driver` says
/// which one when the host named it. Zenity passes `--cancel-label`;
/// `SDL_portaldialog.c` reads no cancel property at all. So a host that named
/// zenity is served, a host that named portal is refused, and a host that named
/// neither is forwarded exactly as it always was: SDL's own detection decides
/// that case, and refusing there would take the label away from a zenity that
/// would have shown it.
///
/// A driver this table does not name keeps its label, because refusing a
/// request the backend could have honoured is the same defect the other way
/// round. The refusal is `FileOutcome.unsupported`, the outcome
/// `portalFileDialog` already returns for the identical request, so a host
/// reads one answer for this option whichever backend answers it.
fn sdlFileRefusal(
    options: FileOptions,
    driver: ?[:0]const u8,
    file_dialog_driver: ?[:0]const u8,
) ?FileOutcome {
    if (options.cancel_label == null) return null;
    const name = driver orelse return null;
    if (std.mem.eql(u8, name, "cocoa") or std.mem.eql(u8, name, "android")) return .unsupported;
    if (std.mem.eql(u8, name, "windows") or std.mem.eql(u8, name, "haiku")) return null;
    if (!std.mem.eql(u8, name, "x11") and !std.mem.eql(u8, name, "wayland")) return null;
    const chosen = file_dialog_driver orelse return null;
    if (std.mem.eql(u8, chosen, "portal")) return .unsupported;
    return null;
}

fn launchSdlFile(
    allocator: std.mem.Allocator,
    options: FileOptions,
    lease: *Lease,
) !void {
    // A cancel label the SDL file dialog cannot show is refused here rather
    // than handed to a panel that would drop it and answer as though it had
    // been served. `portalFileDialog` refuses the identical request, and two
    // backends must not disagree about one option.
    const refusal = sdlFileRefusal(
        options,
        sdl3.video.getCurrentDriverName(),
        sdl3.hints.get(.file_dialog_driver),
    );
    if (refusal) |outcome| {
        bridgeFile(lease, outcome);
        return;
    }

    const call = try allocator.create(SdlFileCall);
    errdefer allocator.destroy(call);
    call.* = .{
        .allocator = allocator,
        .lease = lease,
        .arena = std.heap.ArenaAllocator.init(allocator),
    };
    errdefer call.arena.deinit();
    const scratch = call.arena.allocator();

    var filters: ?[]sdl3.dialog.FileFilter = null;
    if (options.filters.len > 0) {
        const owned = try scratch.alloc(sdl3.dialog.FileFilter, options.filters.len);
        for (options.filters, 0..) |filter, index| {
            // SDL reads these as C strings, so they must be NUL terminated and
            // must outlive the native callback.
            owned[index] = .{
                .name = (try scratch.dupeSentinel(u8, filter.name, 0)).ptr,
                .pattern = (try sdlFilterPattern(scratch, filter)).ptr,
            };
        }
        filters = owned;
    }
    const location: ?[:0]const u8 = if (options.default_location) |value|
        try scratch.dupeSentinel(u8, value, 0)
    else
        null;
    const title: ?[:0]const u8 = if (options.title) |value| try scratch.dupeSentinel(u8, value, 0) else null;
    const accept: ?[:0]const u8 = if (options.accept_label) |value|
        try scratch.dupeSentinel(u8, value, 0)
    else
        null;
    const cancel: ?[:0]const u8 = if (options.cancel_label) |value|
        try scratch.dupeSentinel(u8, value, 0)
    else
        null;

    const parent: ?sdl3.video.Window = if (options.parent_window) |id|
        try nativeWindow(id)
    else
        null;

    const properties = try sdl3.dialog.showWithProperties(
        switch (options.mode) {
            .open_file, .open_multiple_files => .open_file,
            .open_folder => .open_folder,
            .save_file => .save_file,
        },
        SdlFileCall,
        sdlFileCallback,
        call,
        .{
            .filters = filters,
            .window = parent,
            .location = location,
            .many = switch (options.mode) {
                .open_multiple_files => true,
                else => null,
            },
            .title = title,
            .accept = accept,
            .cancel = cancel,
        },
    );
    call.mutex.lock();
    call.properties = properties;
    call.launched = true;
    const completed = call.outcome != null;
    call.mutex.unlock();
    if (completed) call.schedule();
}

/// The SDL message box, which is the only message backend this file uses on
/// every platform: `portalMessageDialog` routes here as well, so there is one
/// path and no second backend to disagree with it.
///
/// Nothing in `MessageOptions` is dropped on the way. The cocoa box reads the
/// title, the message, every button with both of its key equivalents, the
/// style flags and the parent window, and every field above fills one of
/// those, so no message option needs the `unsupported` refusal the file path
/// gives a cancel label the panel cannot show.
fn showSdlMessage(
    allocator: std.mem.Allocator,
    options: MessageOptions,
    lease: *Lease,
) !void {
    const parent: ?sdl3.video.Window = if (options.parent_window) |id|
        try nativeWindow(id)
    else
        null;
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const text = scratch.allocator();

    const title = try text.dupeSentinel(u8, options.title, 0);
    const message = try text.dupeSentinel(u8, options.message, 0);
    const count: usize = if (options.buttons.len == 0) 1 else options.buttons.len;
    const buttons = try text.alloc(sdl3.message_box.Button, count);
    if (options.buttons.len == 0) {
        buttons[0] = .{
            .flags = .{
                .mark_default_with_return_key = true,
                .mark_default_with_escape_key = true,
            },
            .value = 0,
            .text = (try text.dupeSentinel(u8, "OK", 0)).ptr,
        };
    } else {
        for (options.buttons, 0..) |button, index| {
            buttons[index] = .{
                .flags = .{
                    .mark_default_with_return_key = button.is_default,
                    .mark_default_with_escape_key = button.is_escape,
                },
                .value = button.id,
                .text = (try text.dupeSentinel(u8, button.text, 0)).ptr,
            };
        }
    }

    const pressed = sdl3.message_box.show(.{
        .flags = .{
            .error_dialog = options.severity == .critical,
            .warning_dialog = options.severity == .warning,
            .information_dialog = options.severity == .information,
        },
        .parent_window = parent,
        .title = title,
        .message = message,
        .buttons = buttons,
        .color_scheme = null,
    }) catch {
        bridgeMessage(lease, .{ .failed = .native_error });
        return;
    };
    if (pressed < 0) {
        bridgeMessage(lease, .cancelled);
        return;
    }
    bridgeMessage(lease, .{ .pressed = pressed });
}

/// ── Portal file dialog provider ──────────────────────────
/// The portal answers a dialog when a person answers it, and that is not
/// time the host UI thread may spend blocked. The request therefore runs on
/// the worker the host installed, and hands its outcome back on the host UI
/// thread through the same bridge the SDL dialog uses.
/// The provider carries no state: the request travels through the allocator
/// the manager hands in, which leaves the context a non-null sentinel.
var portal_provider_sentinel: u8 = 0;

const portal_file_vtable: DialogProvider.VTable = .{
    .showFileDialog = portalFileDialog,
    .showMessageDialog = portalMessageDialog,
};

/// The file dialog provider backed by `org.freedesktop.portal.FileChooser`.
///
/// Installing it changes the file path only: message dialogs keep the SDL
/// box, because the portal owns no message dialog this tree would replace.
pub fn portalFileProvider() DialogProvider {
    return .{ .context = &portal_provider_sentinel, .vtable = &portal_file_vtable };
}

/// Everything the worker reads after `showFileDialog` returns. The option
/// strings are copies, because the caller's `FileOptions` may die first, and
/// the record itself belongs to the host UI thread once it is posted.
const PortalFileCall = struct {
    allocator: std.mem.Allocator,
    lease: *Lease,
    arena: std.heap.ArenaAllocator,
    options: portal.FileChooserOptions,
    mutex: SpinLock = .{},
    outcome: ?FileOutcome = null,

    fn deinit(self: *PortalFileCall) void {
        self.arena.deinit();
        self.* = undefined;
    }

    fn finishOnMain(self: *PortalFileCall) void {
        const lease = self.lease;
        const outcome = self.outcome.?;
        const allocator = self.allocator;
        self.deinit();
        allocator.destroy(self);
        bridgeFile(lease, outcome);
    }

    fn finishCallback(self: ?*PortalFileCall) void {
        self.?.finishOnMain();
    }

    fn post(self: *PortalFileCall) void {
        sdl3.runOnMainThread(PortalFileCall, finishCallback, self, false) catch {
            // SDL stopped before dispatch. The manager releases its lease
            // half during teardown; this half goes with the outcome.
            var outcome = self.outcome.?;
            const lease = self.lease;
            const allocator = self.allocator;
            self.deinit();
            allocator.destroy(self);
            deinitFileOutcome(&outcome);
            lease.release();
        };
    }
};

/// Run the portal request and turn it into the one outcome the manager
/// reports. The request raises only an allocation failure or a request too
/// large for the wire; both are the host's problem, never a user decision.
fn portalRequestOutcome(call: *PortalFileCall) FileOutcome {
    const result = portal.openFileChooser(
        call.allocator,
        call.options,
        &call.lease.cancelled,
    ) catch |err| switch (err) {
        error.OutOfMemory => return .{ .failed = .out_of_memory },
        // A request the wire cannot carry is this host's problem to report,
        // not a user decision and not an absent capability.
        error.RequestTooLarge => return .{ .failed = .native_error },
    };
    return mapChooserOutcome(call.allocator, result);
}

/// The worker body of one portal request. It owns the record until the
/// outcome is posted, and touches nothing afterwards: from the post on, the
/// record belongs to the host UI thread. The lease outlives this call
/// because the callback side still holds one of its two references, so the
/// cancel flag this reads is always live storage.
fn portalFileCallWork(payload: *anyopaque) void {
    const call: *PortalFileCall = @ptrCast(@alignCast(payload));
    const outcome = portalRequestOutcome(call);
    call.mutex.lock();
    call.outcome = outcome;
    call.mutex.unlock();
    call.post();
}

fn portalFileDialog(
    allocator: std.mem.Allocator,
    _: *anyopaque,
    options: FileOptions,
    callback: FileCallback,
) !void {
    if (comptime builtin.target.os.tag != .linux or builtin.target.abi.isAndroid()) {
        callback.callback(callback.context, .unsupported);
        return;
    }
    const lease: *Lease = @ptrCast(@alignCast(callback.context.?));
    // A cancel label has no documented portal option. The request is refused
    // as a capability this platform cannot serve, rather than sent with a
    // key the portal would accept and ignore.
    if (options.cancel_label != null) {
        callback.callback(callback.context, .unsupported);
        return;
    }
    const manager = lease.owner orelse {
        callback.callback(callback.context, .unsupported);
        return;
    };
    // Without a host worker the request would have to block the host UI
    // thread on a person, which is not a capability this host has enabled.
    const worker = manager.worker orelse {
        callback.callback(callback.context, .unsupported);
        return;
    };

    const call = try allocator.create(PortalFileCall);
    errdefer allocator.destroy(call);
    call.* = .{
        .allocator = allocator,
        .lease = lease,
        .arena = std.heap.ArenaAllocator.init(allocator),
        // SAFETY: assigned on the next line, before any reader exists.
        .options = undefined,
    };
    errdefer call.arena.deinit();
    call.options = try portalFileOptions(call.arena.allocator(), options);

    // A worker that refuses the work frees nothing: the manager still holds
    // both lease references, because no completion was ever started.
    try worker.run(portalFileCallWork, call);
}

/// Message dialogs keep the SDL box, so installing the file provider does
/// not move the message path onto the portal.
fn portalMessageDialog(
    allocator: std.mem.Allocator,
    _: *anyopaque,
    options: MessageOptions,
    callback: MessageCallback,
) !void {
    const lease: *Lease = @ptrCast(@alignCast(callback.context.?));
    try showSdlMessage(allocator, options, lease);
}

/// Copy the caller's request into the portal's shape, owning every string in
/// `arena` because the worker reads them after this call returns.
fn portalFileOptions(
    arena: std.mem.Allocator,
    options: FileOptions,
) !portal.FileChooserOptions {
    var filters: []const portal.FileChooserFilter = &.{};
    if (options.filters.len != 0) {
        const owned = try arena.alloc(portal.FileChooserFilter, options.filters.len);
        for (options.filters, 0..) |filter, index| {
            owned[index] = .{
                .name = try arena.dupe(u8, filter.name),
                .patterns = try portalFilterPatterns(arena, filter),
            };
        }
        filters = owned;
    }
    return .{
        .mode = switch (options.mode) {
            .open_file, .open_multiple_files, .open_folder => .open_file,
            .save_file => .save_file,
        },
        .parent_window = if (options.parent_window) |id|
            try portalParentWindow(arena, id)
        else
            "",
        .title = if (options.title) |title| try arena.dupe(u8, title) else "",
        .accept_label = if (options.accept_label) |label|
            try arena.dupe(u8, label)
        else
            null,
        .multiple = options.mode == .open_multiple_files,
        .directory = options.mode == .open_folder,
        // A request that names a parent is modal for it, which is what
        // `FileOptions.parent_window` documents.
        .modal = options.parent_window != null,
        // The spec takes a raw path here, in the encoding of the file system.
        .current_folder = if (options.default_location) |path|
            try arena.dupe(u8, path)
        else
            null,
        .filters = filters,
    };
}

/// The whole-name globs a portal chooser matches. An `extension` part becomes
/// `*.<part>`, a `glob` part already is one, and a filter carrying `*` on its
/// own carries no patterns at all: a chooser reads an empty pattern list as
/// every file, which is how it builds its own All Files filter, and reads a
/// lone `*` as the file named `*`.
///
/// The parts are cut from copies in `arena`, so they outlive the caller's
/// string and the worker that reads them after this call returns.
fn portalFilterPatterns(
    arena: std.mem.Allocator,
    filter: Filter,
) ![]const []const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(arena);
    var split = std.mem.splitScalar(u8, filter.pattern, ';');
    while (split.next()) |part| {
        if (std.mem.eql(u8, part, "*")) {
            parts.clearRetainingCapacity();
            break;
        }
        try parts.append(arena, switch (filter.match) {
            .extension => try arena.print("*.{s}", .{part}),
            .glob => try arena.dupe(u8, part),
        });
    }
    return parts.toOwnedSlice(arena);
}

/// The extension list `SDL_DialogFileFilter.pattern` takes. An `extension`
/// filter already is one; a `glob` filter is read as a `*.<extension>` list.
/// A glob SDL cannot read that way is refused with `InvalidFilter` instead of
/// being sent as a narrower filter, because a filter that quietly means
/// something else is how a chooser ends up showing an empty view.
fn sdlFilterPattern(arena: std.mem.Allocator, filter: Filter) ![:0]const u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(arena);
    var split = std.mem.splitScalar(u8, filter.pattern, ';');
    while (split.next()) |part| {
        if (std.mem.eql(u8, part, "*")) {
            out.clearRetainingCapacity();
            try out.append(arena, '*');
            break;
        }
        if (out.items.len != 0) try out.append(arena, ';');
        switch (filter.match) {
            .extension => try out.appendSlice(arena, part),
            .glob => {
                // `*.` and nothing after it names no extension at all.
                if (part.len <= 2 or !std.mem.startsWith(u8, part, "*.")) {
                    return error.InvalidFilter;
                }
                try out.appendSlice(arena, part[2..]);
            },
        }
    }
    return arena.dupeSentinel(u8, out.items, 0);
}

/// The window identifier the portal expects, as
/// https://flatpak.github.io/xdg-desktop-portal/docs/window-identifiers.html
/// defines it: `x11:<XID in hexadecimal>` under X11, and
/// `wayland:<handle exported through xdg_foreign>` under Wayland. A window
/// with no such handle is asked for unparented with the empty string, which
/// the same document prescribes. A `wl_surface` pointer is never a handle,
/// so it is never sent.
fn portalParentWindow(arena: std.mem.Allocator, id: sdl3.video.WindowId) ![]const u8 {
    const window = try nativeWindow(id);
    const properties = window.getProperties() catch return "";
    if (properties.x11_window) |xid| {
        return arena.print("x11:{x}", .{@as(u64, @intCast(xid))});
    }
    if (properties.wayland_xdg_toplevel_export_handle) |handle| {
        if (handle.len != 0) return arena.print("wayland:{s}", .{handle});
    }
    return "";
}

/// The portal's result becomes one `FileOutcome` case per outcome. A portal
/// that is not present is not a cancellation, an absent answer is not a
/// cancellation either, and neither is a portal that answered and failed.
fn mapChooserOutcome(
    allocator: std.mem.Allocator,
    result: portal.FileChooserResult,
) FileOutcome {
    return switch (result) {
        .selected => |selection| selectionFromUris(
            allocator,
            selection.uris,
            selection.filter_index,
        ),
        .cancelled => .cancelled,
        .aborted => .aborted,
        .empty_selection => .empty_selection,
        .failed => |failure| switch (failure) {
            .no_session_bus, .portal_unavailable => .unsupported,
            .method_failed, .invalid_reply => .{ .failed = .native_error },
        },
    };
}

/// Take ownership of the portal's URIs and hand back the local paths they
/// name. A URI that is not a local path fails the whole selection instead of
/// shrinking it, because a shorter list is not what the user picked.
fn selectionFromUris(
    allocator: std.mem.Allocator,
    uris: []const []const u8,
    filter_index: ?usize,
) FileOutcome {
    const paths = allocator.alloc([]const u8, uris.len) catch {
        portal.freeUris(allocator, uris);
        return .{ .failed = .out_of_memory };
    };
    errdefer portal.freeUris(allocator, uris);
    var filled: usize = 0;
    errdefer {
        for (paths[0..filled]) |path| allocator.free(path);
        allocator.free(paths);
    }
    for (uris, 0..) |uri, index| {
        paths[index] = portal.fileUriToPath(allocator, uri) catch |err| switch (err) {
            error.OutOfMemory => return .{ .failed = .out_of_memory },
            error.NotAFileUri, error.RemoteHost, error.InvalidEscape => {
                return .{ .failed = .native_error };
            },
        };
        filled += 1;
    }
    portal.freeUris(allocator, uris);
    return .{
        .selected = .{
            .allocator = allocator,
            .paths = paths,
            .filter_index = filter_index,
        },
    };
}

pub const RevealOutcome = enum { revealed, unsupported, failed };

/// Reveal paths in the desktop file manager through the FreeDesktop D-Bus
/// interface. This launches an external application and needs approval.
pub fn revealPath(
    allocator: std.mem.Allocator,
    paths: []const []const u8,
    approval: PointOfRiskApproval,
) !RevealOutcome {
    if (!approval.confirmed) return error.ActionNotApproved;
    if (paths.len == 0) return error.EmptyPath;
    if (comptime builtin.target.os.tag != .linux or builtin.target.abi.isAndroid()) return .unsupported;
    portal.showItems(allocator, paths) catch |err| switch (err) {
        error.NoSessionBus, error.PortalUnavailable => return .unsupported,
        else => return .failed,
    };
    return .revealed;
}

test "api-w18 file filter validation accepts what a chooser answers" {
    // `extension` is what SDL's own filter takes, and the portal reads each
    // part as `*.txt`, so `txt` reaches a real chooser as a pattern it
    // answers.
    try std.testing.expect((Filter{ .name = "Text", .pattern = "txt" }).validate());
    try std.testing.expect((Filter{ .name = "Images", .pattern = "png;jpg;jpeg" }).validate());
    try std.testing.expect((Filter{ .name = "All", .pattern = "*" }).validate());
    try std.testing.expect((Filter{ .name = "Log", .pattern = "tar.gz" }).validate());

    // `glob` is the shape the portal matches against the whole name, so this
    // is the pattern a real chooser answers directly.
    try std.testing.expect(
        (Filter{ .name = "Text", .pattern = "*.txt", .match = .glob }).validate(),
    );
    try std.testing.expect(
        (Filter{ .name = "Text", .pattern = "*.txt;*.md", .match = .glob }).validate(),
    );
    try std.testing.expect(
        (Filter{ .name = "All", .pattern = "*", .match = .glob }).validate(),
    );

    try std.testing.expect(!(Filter{ .name = "", .pattern = "zig" }).validate());
    try std.testing.expect(!(Filter{ .name = "Zig", .pattern = "" }).validate());
    try std.testing.expect(!(Filter{ .name = "Zig", .pattern = "zig;;zon" }).validate());
    try std.testing.expect(!(Filter{ .name = "Shell", .pattern = "sh;ba$h" }).validate());
    try std.testing.expect(!(Filter{ .name = "Nul", .pattern = "zi\x00g" }).validate());
    // `*` is the only wildcard an extension list takes, and only alone.
    try std.testing.expect(!(Filter{ .name = "Zig", .pattern = "*txt" }).validate());
}

test "api-w18 a glob filter with no wildcard is refused instead of emptied" {
    // A part with no `*` names one file, and no directory holds one, which is
    // what emptied the chooser this rule exists for.
    try std.testing.expect(!(Filter{ .name = "Text", .pattern = "txt", .match = .glob }).validate());
    try std.testing.expect(
        !(Filter{ .name = "Text", .pattern = "w18-target.txt", .match = .glob }).validate(),
    );
    try std.testing.expect(!(Filter{ .name = "Text", .pattern = "*.txt;md", .match = .glob }).validate());
    // `?` and the bracket forms mean something to a GTK chooser and nothing to
    // the native panels, so one pattern cannot carry both readings.
    try std.testing.expect(!(Filter{ .name = "Text", .pattern = "*?txt", .match = .glob }).validate());
    try std.testing.expect(
        !(Filter{ .name = "Text", .pattern = "*.[tx]xt", .match = .glob }).validate(),
    );
    // A space is a legal file name byte and belongs in a glob.
    try std.testing.expect(
        (Filter{ .name = "Notes", .pattern = "*.txt;my file*", .match = .glob }).validate(),
    );
}

test "api-w18 each backend receives a filter in the string it reads" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The portal matches whole names, so every extension part becomes a glob
    // of its own and a glob part is already one.
    const extensions = try portalFilterPatterns(arena, .{ .name = "Text", .pattern = "txt;md" });
    try std.testing.expectEqual(@as(usize, 2), extensions.len);
    try std.testing.expectEqualStrings("*.txt", extensions[0]);
    try std.testing.expectEqualStrings("*.md", extensions[1]);
    try std.testing.expectEqualStrings("*.log", (try portalFilterPatterns(arena, .{
        .name = "Logs",
        .pattern = "*.log",
        .match = .glob,
    }))[0]);

    // `*` on its own is every file, and a chooser spells that as a filter with
    // no patterns rather than as a pattern naming the file `*`.
    try std.testing.expectEqual(
        @as(usize, 0),
        (try portalFilterPatterns(arena, .{ .name = "All", .pattern = "*" })).len,
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        (try portalFilterPatterns(arena, .{ .name = "All", .pattern = "*.txt;*", .match = .glob })).len,
    );
    try std.testing.expectEqualStrings("*", try sdlFilterPattern(arena, .{
        .name = "All",
        .pattern = "*",
    }));

    // SDL reads an extension list, so an extension keeps its name and a glob
    // loses the `*.` it carries.
    try std.testing.expectEqualStrings("txt;md", try sdlFilterPattern(arena, .{
        .name = "Text",
        .pattern = "txt;md",
    }));
    try std.testing.expectEqualStrings("log;gz", try sdlFilterPattern(arena, .{
        .name = "Logs",
        .pattern = "*.log;*.gz",
        .match = .glob,
    }));

    // A glob SDL cannot read as an extension is refused, not truncated.
    try std.testing.expectError(error.InvalidFilter, sdlFilterPattern(arena, .{
        .name = "Reports",
        .pattern = "report-*",
        .match = .glob,
    }));
    try std.testing.expectError(error.InvalidFilter, sdlFilterPattern(arena, .{
        .name = "Dot",
        .pattern = "*.",
        .match = .glob,
    }));
}

test "api-w18 selection ownership copies and rejects an empty success list" {
    try std.testing.expectError(
        error.EmptySelection,
        FileSelection.init(std.testing.allocator, &.{}, null),
    );

    var source = [_][]const u8{ "/tmp/one.zig", "/tmp/two.zig" };
    var selection = try FileSelection.init(std.testing.allocator, &source, 2);
    defer selection.deinit();

    try std.testing.expectEqual(@as(usize, 2), selection.paths.len);
    try std.testing.expectEqual(@as(?usize, 2), selection.filter_index);
    try std.testing.expectEqualStrings("/tmp/one.zig", selection.paths[0]);

    // The owned copy must survive losing the source buffer.
    source[0] = "changed";
    try std.testing.expectEqualStrings("/tmp/one.zig", selection.paths[0]);
}

test "api-w18 unapproved launches never reach a provider" {
    var manager = DialogManager.init(std.testing.allocator);
    defer manager.deinit();

    const Counter = struct {
        var calls: usize = 0;
        fn file(_: std.mem.Allocator, _: *anyopaque, _: FileOptions, _: FileCallback) anyerror!void {
            calls += 1;
        }
        fn message(_: std.mem.Allocator, _: *anyopaque, _: MessageOptions, _: MessageCallback) anyerror!void {
            calls += 1;
        }
    };
    const vtable: DialogProvider.VTable = .{
        .showFileDialog = Counter.file,
        .showMessageDialog = Counter.message,
    };
    manager.setProvider(.{ .context = @ptrFromInt(1), .vtable = &vtable });

    const Ignore = struct {
        fn file(_: ?*anyopaque, outcome: FileOutcome) void {
            var mut_outcome = outcome;
            deinitFileOutcome(&mut_outcome);
        }
        fn message(_: ?*anyopaque, _: MessageOutcome) void {}
    };
    try std.testing.expectError(error.ActionNotApproved, manager.showFile(
        .{},
        .{},
        .{ .callback = Ignore.file },
    ));
    try std.testing.expectError(error.ActionNotApproved, manager.showMessage(
        .{ .title = "t", .message = "m" },
        .{},
        .{ .callback = Ignore.message },
    ));
    try std.testing.expectError(error.ActionNotApproved, revealPath(
        std.testing.allocator,
        &.{"/tmp"},
        .{},
    ));
    try std.testing.expectEqual(@as(usize, 0), Counter.calls);
}

/// A provider that records the lease it was launched with, so a test can
/// observe the cancel flag a parked request would poll.
const LeaseWatcher = struct {
    lease: ?*Lease = null,
    pending: ?FileCallback = null,
    calls: usize = 0,
    cancelled_at_launch: bool = true,

    fn file(
        _: std.mem.Allocator,
        context: *anyopaque,
        _: FileOptions,
        callback: FileCallback,
    ) anyerror!void {
        const self: *LeaseWatcher = @ptrCast(@alignCast(context));
        const lease: *Lease = @ptrCast(@alignCast(callback.context.?));
        self.calls += 1;
        self.lease = lease;
        self.cancelled_at_launch = lease.cancelled.load(.acquire);
        self.pending = callback;
    }

    fn message(
        _: std.mem.Allocator,
        _: *anyopaque,
        _: MessageOptions,
        _: MessageCallback,
    ) anyerror!void {}

    const vtable: DialogProvider.VTable = .{
        .showFileDialog = file,
        .showMessageDialog = message,
    };
};

test "api-w18 a parent close tells a still-running provider to stop" {
    var manager = DialogManager.init(std.testing.allocator);
    defer manager.deinit();
    var watcher: LeaseWatcher = .{};
    manager.setProvider(.{ .context = &watcher, .vtable = &LeaseWatcher.vtable });

    const Receiver = struct {
        calls: usize = 0,
        outcome: ?FileOutcome = null,
        fn onResult(context: ?*anyopaque, outcome: FileOutcome) void {
            const Self = @This();
            const self: *Self = @ptrCast(@alignCast(context.?));
            self.calls += 1;
            if (self.outcome) |*previous| deinitFileOutcome(previous);
            self.outcome = outcome;
        }
    };
    var receiver: Receiver = .{};
    defer if (receiver.outcome) |*outcome| deinitFileOutcome(outcome);

    try manager.showFile(
        .{ .mode = .open_file, .parent_window = 7 },
        .{ .confirmed = true },
        .{ .context = &receiver, .callback = Receiver.onResult },
    );
    try std.testing.expectEqual(@as(usize, 1), watcher.calls);
    try std.testing.expect(!watcher.cancelled_at_launch);

    // The manager resolves the request itself. The provider still holds one
    // of the lease's two references, so the flag it will poll is still live.
    manager.onWindowClosed(7);
    try std.testing.expectEqual(@as(usize, 1), receiver.calls);
    try std.testing.expectEqual(FileOutcome.parent_closed, receiver.outcome.?);
    try std.testing.expect(watcher.lease.?.cancelled.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), manager.pendingCount());

    // The late completion is dropped, and the provider's reference goes with
    // it, which is what ends the lease.
    const parked = watcher.pending orelse return error.NoParkedRequest;
    parked.callback(parked.context, .cancelled);
    try std.testing.expectEqual(@as(usize, 1), receiver.calls);
}

test "api-w18 manager teardown tells every parked request to stop" {
    var watcher: LeaseWatcher = .{};
    var receiver_outcome: ?FileOutcome = null;
    const Receiver = struct {
        fn onResult(context: ?*anyopaque, outcome: FileOutcome) void {
            const slot: *?FileOutcome = @ptrCast(@alignCast(context.?));
            slot.* = outcome;
        }
    };
    {
        var manager = DialogManager.init(std.testing.allocator);
        manager.setProvider(.{ .context = &watcher, .vtable = &LeaseWatcher.vtable });
        try manager.showFile(
            .{ .mode = .open_file, .parent_window = 11 },
            .{ .confirmed = true },
            .{ .context = &receiver_outcome, .callback = Receiver.onResult },
        );
        try std.testing.expect(!watcher.cancelled_at_launch);
        manager.deinit();
    }
    // The provider's reference is what keeps the lease alive here, so the
    // flag a parked worker polls can still be read after teardown.
    try std.testing.expect(watcher.lease.?.cancelled.load(.acquire));
    try std.testing.expect(receiver_outcome == null);
    const parked = watcher.pending orelse return error.NoParkedRequest;
    parked.callback(parked.context, .cancelled);
    try std.testing.expect(receiver_outcome == null);
}

test "api-w18 a portal request without a host worker is refused as unsupported" {
    var manager = DialogManager.init(std.testing.allocator);
    defer manager.deinit();
    // No worker is installed and no provider is set, so the launch reaches
    // the SDL path. The portal provider is installed with a cancel label the
    // portal has no documented option for, which must never reach a bus.
    manager.setProvider(portalFileProvider());

    const Receiver = struct {
        calls: usize = 0,
        outcome: ?FileOutcome = null,
        fn onResult(context: ?*anyopaque, outcome: FileOutcome) void {
            const Self = @This();
            const self: *Self = @ptrCast(@alignCast(context.?));
            self.calls += 1;
            if (self.outcome) |*previous| deinitFileOutcome(previous);
            self.outcome = outcome;
        }
    };
    var receiver: Receiver = .{};
    defer if (receiver.outcome) |*outcome| deinitFileOutcome(outcome);

    try manager.showFile(
        .{ .mode = .open_file, .cancel_label = "Nope" },
        .{ .confirmed = true },
        .{ .context = &receiver, .callback = Receiver.onResult },
    );
    try std.testing.expectEqual(@as(usize, 1), receiver.calls);
    try std.testing.expectEqual(FileOutcome.unsupported, receiver.outcome.?);
    try std.testing.expectEqual(@as(usize, 0), manager.pendingCount());
}

/// The shape the binding hands over: SDL names the chosen paths in a
/// `const char * const *` whose own null slot ends the array, and the binding
/// counts that array up to the null before it slices it, so two chosen paths
/// arrive as two slots. The null is what the count stops at, not a slot this
/// list carries, and the element type is a C string pointer rather than an
/// optional, so no fixture here can spell one.
const chosen_paths = [_][*:0]const u8{ "/tmp/one.zig", "/tmp/two.zig" };

test "api-w18 a native path list names every path the binding counted" {
    var selection = try FileSelection.fromNativeList(std.testing.allocator, chosen_paths[0..], 0);
    defer selection.deinit();

    // Two chosen paths, not a third: the null that ends SDL's array is what
    // the binding counted against, so it is not a slot here and no read can
    // reach past the slice to span it.
    try std.testing.expectEqual(@as(usize, 2), selection.paths.len);
    try std.testing.expectEqual(@as(?usize, 0), selection.filter_index);
    try std.testing.expectEqualStrings("/tmp/one.zig", selection.paths[0]);
    try std.testing.expectEqualStrings("/tmp/two.zig", selection.paths[1]);

    // The dismissal shape is a list naming nothing, because that is what the
    // count leaves behind when nobody chose a path: a dismissal is reported
    // as `cancelled` and never as a success with no paths.
    const nameless: [0][*:0]const u8 = .{};
    try std.testing.expectError(
        error.EmptySelection,
        FileSelection.fromNativeList(std.testing.allocator, nameless[0..], null),
    );
}

test "api-w18 the SDL callback keeps a dismissal, a failure and a choice apart" {
    // This callback only records its outcome while `launched` is false, so no
    // bridge runs and no lease is read; the arena is never asked for bytes.
    var call: SdlFileCall = .{
        .allocator = std.testing.allocator,
        .lease = undefined,
        .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
    };

    // A dismissed dialog: SDL passes a pointer to nothing.
    sdlFileCallback(&call, null, null, false);
    try std.testing.expectEqual(FileOutcome.cancelled, call.outcome.?);

    // A native error is the one shape that is a failure, and it is reported
    // even when the list SDL passes beside it names paths.
    sdlFileCallback(&call, chosen_paths[0..], 0, true);
    try std.testing.expectEqual(FileOutcome{ .failed = .native_error }, call.outcome.?);

    // Chosen paths, in the counted slice shape the binding hands over.
    sdlFileCallback(&call, chosen_paths[0..], 0, false);
    switch (call.outcome.?) {
        .selected => |*selection| {
            try std.testing.expectEqual(@as(usize, 2), selection.paths.len);
            try std.testing.expectEqualStrings("/tmp/one.zig", selection.paths[0]);
            try std.testing.expectEqualStrings("/tmp/two.zig", selection.paths[1]);
            selection.deinit();
        },
        else => return error.TestUnexpectedResult,
    }

    // An accepted dialog that named nothing arrives as a list naming nothing,
    // because the binding counted SDL's array before it reached us; it is the
    // dismissed shape here, so only a provider that reads the response code
    // can report `empty_selection`.
    const named_nothing: [0][*:0]const u8 = .{};
    sdlFileCallback(&call, named_nothing[0..], null, false);
    try std.testing.expectEqual(FileOutcome.cancelled, call.outcome.?);
}

/// A provider that answers with the one outcome the test names, delivered
/// through the same lease path a real backend completes on.
const ScriptedProvider = struct {
    outcome: FileOutcome,
    calls: usize = 0,

    fn file(
        _: std.mem.Allocator,
        context: *anyopaque,
        _: FileOptions,
        callback: FileCallback,
    ) anyerror!void {
        const self: *ScriptedProvider = @ptrCast(@alignCast(context));
        self.calls += 1;
        callback.callback(callback.context, self.outcome);
    }

    fn message(
        _: std.mem.Allocator,
        _: *anyopaque,
        _: MessageOptions,
        _: MessageCallback,
    ) anyerror!void {}

    const vtable: DialogProvider.VTable = .{
        .showFileDialog = file,
        .showMessageDialog = message,
    };
};

test "api-w18 cancelled, failed and empty selection stay three outcomes" {
    const Receiver = struct {
        calls: usize = 0,
        outcome: ?FileOutcome = null,
        fn onResult(context: ?*anyopaque, outcome: FileOutcome) void {
            const Self = @This();
            const self: *Self = @ptrCast(@alignCast(context.?));
            self.calls += 1;
            if (self.outcome) |*previous| deinitFileOutcome(previous);
            self.outcome = outcome;
        }
    };

    // Each shape is its own tag and reaches the receiver as that tag, so a
    // dismissed dialog, a broken one and an accepted one that named nothing
    // never collapse into each other on the way out.
    const cases = [_]struct { scripted: FileOutcome, want: FileOutcome }{
        .{ .scripted = .cancelled, .want = .cancelled },
        .{ .scripted = .aborted, .want = .aborted },
        .{ .scripted = .empty_selection, .want = .empty_selection },
        .{ .scripted = .{ .failed = .native_error }, .want = .{ .failed = .native_error } },
        .{ .scripted = .{ .failed = .out_of_memory }, .want = .{ .failed = .out_of_memory } },
        .{ .scripted = .unsupported, .want = .unsupported },
        .{ .scripted = .parent_closed, .want = .parent_closed },
    };
    for (cases) |case| {
        var manager = DialogManager.init(std.testing.allocator);
        defer manager.deinit();
        var provider: ScriptedProvider = .{ .outcome = case.scripted };
        manager.setProvider(.{ .context = &provider, .vtable = &ScriptedProvider.vtable });
        var receiver: Receiver = .{};
        defer if (receiver.outcome) |*outcome| deinitFileOutcome(outcome);

        try manager.showFile(
            .{ .mode = .open_file },
            .{ .confirmed = true },
            .{ .context = &receiver, .callback = Receiver.onResult },
        );
        try std.testing.expectEqual(@as(usize, 1), provider.calls);
        try std.testing.expectEqual(@as(usize, 1), receiver.calls);
        try std.testing.expectEqual(case.want, receiver.outcome.?);
        // Every shape is resolved, so none of them leaves the request parked.
        try std.testing.expectEqual(@as(usize, 0), manager.pendingCount());
    }
}

test "api-w18 a selection is never a success that named no path" {
    const cases = [_]struct { list: []const [*:0]const u8, filter: ?usize }{
        .{ .list = chosen_paths[0..], .filter = 0 },
        .{ .list = chosen_paths[0..], .filter = null },
        .{ .list = chosen_paths[1..], .filter = null },
    };
    for (cases) |case| {
        var selection = try FileSelection.fromNativeList(
            std.testing.allocator,
            case.list,
            case.filter,
        );
        defer selection.deinit();
        try std.testing.expect(selection.paths.len > 0);
        for (selection.paths) |path| try std.testing.expect(path.len > 0);
    }
}

test "api-w18 a cancel label the SDL file dialog cannot show is refused, not dropped" {
    // The cocoa panel reads no cancel property, so the request is refused
    // with the same typed outcome the portal path returns for it.
    try std.testing.expectEqual(
        FileOutcome.unsupported,
        sdlFileRefusal(.{ .cancel_label = "Nope" }, "cocoa", null).?,
    );
    // The android document picker reads no cancel property either.
    try std.testing.expectEqual(
        FileOutcome.unsupported,
        sdlFileRefusal(.{ .cancel_label = "Nope" }, "android", null).?,
    );
    // On the unix backends the host's own choice of file dialog says which
    // backend answers, and only SDL's portal one drops the label.
    try std.testing.expectEqual(
        FileOutcome.unsupported,
        sdlFileRefusal(.{ .cancel_label = "Nope" }, "x11", "portal").?,
    );
    try std.testing.expectEqual(
        FileOutcome.unsupported,
        sdlFileRefusal(.{ .cancel_label = "Nope" }, "wayland", "portal").?,
    );
    try std.testing.expectEqual(
        @as(?FileOutcome, null),
        sdlFileRefusal(.{ .cancel_label = "Nope" }, "x11", "zenity"),
    );
    // Windows and Haiku read the property, so they still show the label.
    try std.testing.expectEqual(
        @as(?FileOutcome, null),
        sdlFileRefusal(.{ .cancel_label = "Nope" }, "windows", null),
    );
    try std.testing.expectEqual(
        @as(?FileOutcome, null),
        sdlFileRefusal(.{ .cancel_label = "Nope" }, "haiku", null),
    );
    // A unix host that named no backend keeps the label it always had, and a
    // driver this file does not name is never refused on a guess.
    try std.testing.expectEqual(
        @as(?FileOutcome, null),
        sdlFileRefusal(.{ .cancel_label = "Nope" }, "x11", null),
    );
    try std.testing.expectEqual(
        @as(?FileOutcome, null),
        sdlFileRefusal(.{ .cancel_label = "Nope" }, "offscreen", null),
    );
    try std.testing.expectEqual(
        @as(?FileOutcome, null),
        sdlFileRefusal(.{ .cancel_label = "Nope" }, null, null),
    );

    // Every other option the shared request carries reaches that panel, so a
    // request without a cancel label opens a dialog exactly as it did.
    const honoured = [_]FileOptions{
        .{},
        .{ .mode = .open_multiple_files },
        .{ .mode = .open_folder },
        .{ .mode = .save_file },
        .{ .title = "Open" },
        .{ .default_location = "/tmp" },
        .{ .filters = &.{.{ .name = "Text", .pattern = "txt" }} },
        .{ .accept_label = "Pick" },
        .{ .parent_window = 3 },
    };
    const dropping = [_]?[:0]const u8{ "cocoa", "android" };
    for (honoured) |options| {
        for (dropping) |driver| {
            const got = sdlFileRefusal(options, driver, null);
            try std.testing.expectEqual(@as(?FileOutcome, null), got);
        }
    }
}

test "api-w18 the refused cancel label reaches the receiver as unsupported" {
    var manager = DialogManager.init(std.testing.allocator);
    defer manager.deinit();

    const Receiver = struct {
        calls: usize = 0,
        outcome: ?FileOutcome = null,
        fn onResult(context: ?*anyopaque, outcome: FileOutcome) void {
            const Self = @This();
            const self: *Self = @ptrCast(@alignCast(context.?));
            self.calls += 1;
            if (self.outcome) |*previous| deinitFileOutcome(previous);
            self.outcome = outcome;
        }
    };
    var receiver: Receiver = .{};
    defer if (receiver.outcome) |*outcome| deinitFileOutcome(outcome);

    // The refusal travels the same lease the portal path uses, so the receiver
    // is answered with that typed outcome and the request is not left parked
    // behind a dialog that would have dropped the label.
    const lease = try manager.addLease(null, .{
        .file = .{ .context = &receiver, .callback = Receiver.onResult },
    });
    bridgeFile(lease, sdlFileRefusal(.{ .cancel_label = "Nope" }, "cocoa", null).?);
    try std.testing.expectEqual(@as(usize, 1), receiver.calls);
    try std.testing.expectEqual(FileOutcome.unsupported, receiver.outcome.?);
    try std.testing.expectEqual(@as(usize, 0), manager.pendingCount());
}
