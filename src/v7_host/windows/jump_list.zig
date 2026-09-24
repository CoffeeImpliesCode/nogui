//! Windows jump list, recent documents, and the router for a selected entry.
//!
//! The jump list is the Windows analogue of the dock menu and the recent
//! document list in `menus.zig`, and it takes the same two models:
//! `menus.JumpListTask` for the Tasks category and `menus.RecentDocument` for
//! the Recent category. Nothing here invents a second task runtime or a second
//! recent-document store.
//!
//! Four parts, deliberately separated:
//!
//!   * The identity gate. A jump list belongs to the taskbar button of the app
//!     whose `AppUserModelID` names it, so `SetCurrentProcessExplicitAppUser-
//!     ModelID` has to have run first. The gate is a pure function over the
//!     declared and the held identity, it is checked before any COM call, and
//!     it is refused by name. The shim checks it again at its own boundary,
//!     because the shim is the only place that touches COM.
//!   * The model. `build` widens the shared models into the borrowed views the
//!     shell takes. It is pure Zig and runs on every target, so the conversion
//!     is observable without a shell.
//!   * The router. A jump list entry survives the window it was published for,
//!     so a selection can name a window that is gone. `Router` picks the
//!     target by identity, re-checks the weak owner, and dispatches through
//!     `menus.MenuActionBridge` against the `nogui.action.Registry` of the
//!     target window. A dead window is dropped and its route forgotten, never
//!     resurrected and never handed to the next window that shares the action
//!     name.
//!   * The launch door. A jump list entry is not an in-process event: the
//!     shell launches this process with the entry as its only argument, and
//!     that argument is all the shell sent. `processCommandLine` reads the
//!     command line the process was actually STARTED with through the shell's
//!     own splitter, `decodeLaunchArgument` names the entry that argument is
//!     against the models this build publishes, and `Router.activate` routes
//!     it under the same dead-window and ambiguity rules `dispatch` uses. An
//!     argument that names nothing published is `error.UnknownActivation`,
//!     one that names two is `error.AmbiguousLaunchArgument`, and a window
//!     that is gone is `error.WindowGone` -- three answers, each by name,
//!     because a process the operator started by hand decoded none of them.
//!
//!     The door closes in this order and the order is the contract: an
//!     argument is DECODED against the models this build published before any
//!     window is activated, and `Router.activate` accepts only the decoded
//!     `Activation`, never a raw string. Because `Activation` is a plain
//!     string union a caller could still build by hand, the router repeats the
//!     decode's ambiguity rule itself -- the last thing between an argument and
//!     a live dispatch owns that rule. A published task is refused unless its
//!     action name is ONE whole argument, because `IShellLink::SetArguments`
//!     takes a command-line tail that nothing escapes: a name the shell's own
//!     splitter would break in two is an entry in the user's taskbar menu that
//!     does nothing when it is chosen.
//! The COM itself is behind `native/nogui_jumplist.c`. A jump list is a list of
//! COM objects declared in `shobjidl_core.h`, and the vtables come from that
//! SDK header through the C compiler, so no interface is hand-written here.
const std = @import("std");
const nogui = @import("nogui");
const action = nogui.action;
const WidgetId = nogui.WidgetId;
const WidgetTree = nogui.WidgetTree;
pub const WindowHandle = nogui.window_contract.WindowHandle;
const app_identity = @import("app_identity.zig");
const menus = @import("../menus.zig");
const weak_owner = @import("../weak_owner.zig");
const win = @import("win32.zig");

pub const is_windows = win.is_windows;
pub const JumpListTask = menus.JumpListTask;
pub const RecentDocument = menus.RecentDocument;

// --- the shim ABI -----------------------------------------------------------

/// Mirrors `nogui_jump_status` in `native/nogui_jumplist.h`.
pub const Status = enum(c_int) {
    ok = 0,
    identity_unset = 1,
    com_unavailable = 2,
    shell_refused = 3,
    invalid_entry = 4,
    /// The identity the caller asked for is not the one the process holds, so the
    /// list would be filed under another app's taskbar button.
    identity_mismatch = 5,
    out_of_memory = 6,
};

/// One task as the shell takes it. Every pointer is borrowed for the duration
/// of the call.
pub const TaskView = extern struct {
    title: ?[*:0]const u16,
    action_name: ?[*:0]const u16,
    description: ?[*:0]const u16,
};

/// One recent document as the shell takes it.
pub const DocumentView = extern struct {
    path: ?[*:0]const u16,
    display_name: ?[*:0]const u16,
};

pub extern fn nogui_jump_publish(
    app_id: ?[*:0]const u16,
    tasks: ?[*]const TaskView,
    task_count: c_uint,
    documents: ?[*]const DocumentView,
    document_count: c_uint,
) callconv(.c) Status;

// --- errors -----------------------------------------------------------------

pub const Error = error{
    /// This build has no Windows jump list to publish into.
    NotWindows,
    /// The process holds no explicit `AppUserModelID`, so there is no taskbar
    /// button for a list to belong to.
    IdentityUnset,
    /// The identity the app declared is not the identity the process holds.
    IdentityMismatch,
    /// The declared identity breaks the shell's own grammar.
    IdentityMalformed,
    /// COM could not be initialized, or the shell refused to create the list.
    ComUnavailable,
    /// The shell refused a list operation.
    ShellRefused,
    /// An entry names nothing -- an empty title, action name or document path
    /// -- or a task's action name is not one whole argument, so the shell's own
    /// splitter would break the published command line and `decodeLaunchArgument`
    /// could never name it again.
    InvalidEntry,
    /// A title, action name, description or document path is not valid UTF-8,
    /// so it cannot be widened for the shell. Refused by name rather than
    /// published with a replacement character in it, because a mangled action
    /// name is a different action.
    InvalidUtf8,
} || std.mem.Allocator.Error;

/// The refusal a status names, or null for the one status that is not a
/// refusal. Every status is accounted for, so a status the shim adds later
/// cannot slip through as a success.
fn errorOf(status: Status) ?Error {
    return switch (status) {
        .ok => null,
        .identity_unset => error.IdentityUnset,
        .identity_mismatch => error.IdentityMismatch,
        .com_unavailable => error.ComUnavailable,
        .shell_refused => error.ShellRefused,
        .invalid_entry => error.InvalidEntry,
        .out_of_memory => error.OutOfMemory,
    };
}

/// Release one identity that came out of an optional or a by-value copy.
fn releaseIdentity(value: app_identity.Identity) void {
    var owned = value;
    owned.deinit();
}

// --- the identity gate ------------------------------------------------------

/// The refusals the identity gate can name.
pub const IdentityError = error{
    IdentityUnset,
    IdentityMismatch,
    IdentityMalformed,
};

/// Whether the process may build a jump list.
///
/// `declared` is the identity the app chose, or null when it declared none.
/// `held` is what `GetCurrentProcessExplicitAppUserModelID` reported, or null
/// when the process holds no explicit identity at all. Null means "refuse,
/// never guess": the shell's fallback is the executable path, and a list filed
/// under a development build's own path is grouped with nothing and reaches no
/// taskbar button the app can name.
pub fn identityAdmits(declared: ?[]const u8, held: ?[]const u8) IdentityError!void {
    const wanted = declared orelse return error.IdentityUnset;
    if (!app_identity.isWellFormed(wanted)) return error.IdentityMalformed;
    const actual = held orelse return error.IdentityUnset;
    if (!std.mem.eql(u8, actual, wanted)) return error.IdentityMismatch;
}

// --- the model --------------------------------------------------------------

/// One task, widened. Owned by the `Model` that built it.
pub const Task = struct {
    title: [:0]u16,
    action_name: [:0]u16,
    description: ?[:0]u16 = null,

    fn view(self: Task) TaskView {
        return .{
            .title = self.title.ptr,
            .action_name = self.action_name.ptr,
            .description = if (self.description) |text| text.ptr else null,
        };
    }
};

/// One recent document, widened. Owned by the `Model` that built it.
pub const Document = struct {
    path: [:0]u16,
    display_name: ?[:0]u16 = null,

    fn view(self: Document) DocumentView {
        return .{
            .path = self.path.ptr,
            .display_name = if (self.display_name) |name| name.ptr else null,
        };
    }
};

/// Whether one argument can be the WHOLE argument of a process the shell
/// started.
///
/// `IShellLink::SetArguments` takes a command-line TAIL rather than a list: the
/// shell appends the string to the target path as it stands and its own splitter
/// breaks the result afterwards. So whitespace splits one entry into two
/// arguments, a double quote opens a quoted run the action name never ends, and
/// a trailing backslash escapes the quote the shell puts around the rest.
///
/// A name carrying any of those reaches the user's taskbar menu and comes back
/// as an argument vector this process cannot read as one entry, so the entry
/// does nothing when it is chosen. `JumpList.build` refuses it before the shell
/// is asked, and `native/nogui_jumplist.c` refuses it again at the boundary that
/// writes the argument list.
///
/// Only a task's ACTION NAME travels this way. A document's path is quoted by
/// the file-type registration that launches it, which is a separate statement
/// from this one, so a path with a space in it is left alone here.
pub fn isWholeLaunchArgument(argument: []const u8) bool {
    if (argument.len == 0) return false;
    if (argument[argument.len - 1] == '\\') return false;
    for (argument) |byte| switch (byte) {
        ' ', '\t', '\n', '\r', 0x0b, 0x0c, '"' => return false,
        else => {},
    };
    return true;
}

/// The widened model one publish carries. An arena owns every string, so
/// releasing the model is one call and there is no per-entry bookkeeping to get
/// wrong.
pub const Model = struct {
    arena: std.heap.ArenaAllocator,
    tasks: []Task = &.{},
    documents: []Document = &.{},

    pub fn deinit(self: *Model) void {
        self.arena.deinit();
        self.tasks = &.{};
        self.documents = &.{};
        self.* = undefined;
    }
};

// --- the list ---------------------------------------------------------------

/// The jump list of one process.
///
/// The models are borrowed. The caller owns them and must keep them for as long
/// as it may call `publish`, which is the same rule every other adapter in this
/// directory follows for a caller-owned model.
pub const JumpList = struct {
    gpa: std.mem.Allocator,
    /// The identity this list belongs to. Set once, from
    /// `app_identity.setProcessIdentity`, and never derived.
    identity: ?app_identity.Identity = null,
    tasks: []const JumpListTask = &.{},
    documents: []const RecentDocument = &.{},

    pub fn init(gpa: std.mem.Allocator) JumpList {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *JumpList) void {
        if (self.identity) |owned| releaseIdentity(owned);
        self.identity = null;
        self.tasks = &.{};
        self.documents = &.{};
        self.* = undefined;
    }

    /// Take ownership of the identity this list belongs to. A second identity
    /// replaces the first, so a process that re-registered is not publishing
    /// two identities' lists.
    pub fn setIdentity(self: *JumpList, identity: app_identity.Identity) void {
        if (self.identity) |previous| releaseIdentity(previous);
        self.identity = identity;
    }

    /// The tasks the Tasks category shows. Borrowed.
    pub fn setJumpListTasks(self: *JumpList, tasks: []const JumpListTask) void {
        self.tasks = tasks;
    }

    /// The documents the Recent category shows. Borrowed.
    pub fn setRecentDocuments(self: *JumpList, documents: []const RecentDocument) void {
        self.documents = documents;
    }

    /// The identity this list claims, or null when the app declared none.
    pub fn identityName(self: *const JumpList) ?[]const u8 {
        const owned = self.identity orelse return null;
        return owned.app_id;
    }

    /// Widen the borrowed models into the views the shell takes.
    ///
    /// This is the whole conversion, and it is pure: no COM, no window, no
    /// identity. An entry whose strings cannot be widened is refused by name
    /// rather than published as a replacement character, because a mangled
    /// action name is a different action.
    pub fn build(self: *JumpList) Error!Model {
        var model: Model = .{ .arena = std.heap.ArenaAllocator.init(self.gpa) };
        errdefer model.deinit();
        const alloc = model.arena.allocator();

        model.tasks = try alloc.alloc(Task, self.tasks.len);
        for (self.tasks, 0..) |task, index| {
            if (task.title.len == 0 or task.action_name.len == 0) {
                return error.InvalidEntry;
            }
            if (!isWholeLaunchArgument(task.action_name)) return error.InvalidEntry;
            model.tasks[index] = .{
                .title = try win.wide(alloc, task.title),
                .action_name = try win.wide(alloc, task.action_name),
                .description = if (task.description) |text|
                    try win.wide(alloc, text)
                else
                    null,
            };
        }

        model.documents = try alloc.alloc(Document, self.documents.len);
        for (self.documents, 0..) |document, index| {
            if (document.path.len == 0) return error.InvalidEntry;
            model.documents[index] = .{
                .path = try win.wide(alloc, document.path),
                .display_name = if (document.display_name) |name|
                    try win.wide(alloc, name)
                else
                    null,
            };
        }
        return model;
    }

    /// Publish the list.
    ///
    /// The identity gate runs first, before the model is built and before the
    /// shim is called, and the shim repeats it before it initializes COM. A
    /// refusal from either layer is the same refusal by the same name.
    pub fn publish(self: *JumpList) Error!void {
        if (comptime !win.is_windows) return error.NotWindows;

        const held = app_identity.currentProcessIdentity(self.gpa) catch null;
        defer if (held) |value| releaseIdentity(value);
        try identityAdmits(
            self.identityName(),
            if (held) |value| value.app_id else null,
        );

        const owned = self.identity orelse return error.IdentityUnset;
        var model = try self.build();
        defer model.deinit();

        const task_views = try self.gpa.alloc(TaskView, model.tasks.len);
        defer self.gpa.free(task_views);
        for (model.tasks, 0..) |task, index| task_views[index] = task.view();

        const document_views = try self.gpa.alloc(DocumentView, model.documents.len);
        defer self.gpa.free(document_views);
        for (model.documents, 0..) |document, index| {
            document_views[index] = document.view();
        }

        const wide_id = try win.wide(self.gpa, owned.app_id);
        defer {
            win.wipe(std.mem.sliceAsBytes(wide_id));
            self.gpa.free(wide_id);
        }

        const status = nogui_jump_publish(
            wide_id.ptr,
            if (task_views.len == 0) null else task_views.ptr,
            @intCast(task_views.len),
            if (document_views.len == 0) null else document_views.ptr,
            @intCast(document_views.len),
        );
        if (errorOf(status)) |refusal| return refusal;
    }
};

// --- the selected-action router ---------------------------------------------

/// What the user chose from the jump list. The shell reports a task and a
/// recent document through different paths, so they are two cases here rather
/// than one string field.
pub const Selection = union(enum) {
    task: JumpListTask,
    document: RecentDocument,
};

// --- the shell's launch door ------------------------------------------------

/// What the shell put on this process's command line.
///
/// The shim publishes a task as a shortcut to this process whose argument list
/// is the task's action name -- that is what `IShellLink::SetArguments` is
/// given -- and it records a document through `SHAddToRecentDocs`, which the
/// shell launches by that document's path through the file type this program
/// is registered to open. So a shell-launched entry arrives as an argument,
/// and this is the union of the two things that argument can be.
pub const Activation = union(enum) {
    /// The published action name of a task.
    task: []const u8,
    /// The published path of a recent document.
    document: []const u8,
};

/// The refusals the launch door names.
///
/// They are named rather than folded into one "nothing decoded", because the
/// answers are different facts about this run: a build with no Windows command
/// line, a shell that would not split the line it wrote, an argument that
/// matches nothing this build publishes, and an argument that matches two
/// things at once are not one another's missing case.
pub const LaunchError = error{
    /// This build has no Windows command line to read.
    NotWindows,
    /// The shell refused to split the command line it wrote.
    ShellRefused,
    /// The argument names no entry this process publishes.
    UnknownActivation,
    /// The argument names a task and a document at once, so it has two
    /// answers and picking one would be a guess about which list the person
    /// who chose it was looking at.
    AmbiguousLaunchArgument,
} || std.mem.Allocator.Error;

/// The one launch argument an argument vector carries, or null when it
/// carries none.
///
/// The rule is the shell's own, not this adapter's: every entry this
/// directory publishes is launched as `<executable> <the entry's own
/// argument>` -- a task link's argument list is the action name and nothing
/// else, and a document launch is the file handler followed by the path and
/// nothing else. A vector of any other length was typed by a person, and a
/// person typing flags has not handed this process an entry, so such a line
/// is an ordinary invocation and is never decoded as an activation.
pub fn launchArgumentFromArgv(argv: []const []const u8) ?[]const u8 {
    if (argv.len != 2) return null;
    return argv[1];
}

/// THIS PROCESS's own command line, split by the shell's own splitter.
///
/// `GetCommandLineW` is what the shell wrote when it launched this process, and
/// `CommandLineToArgvW` is the shell's own quoting, so a path with spaces in
/// it decodes into the argument the shell meant. Every entry is owned UTF-8,
/// because the models this decodes against are UTF-8 and a path this adapter
/// cannot spell is not a path it may substitute.
pub const ProcessCommandLine = struct {
    gpa: std.mem.Allocator,
    /// The whole argument vector, argv[0] included, exactly as the shell's own
    /// splitter produced it. It is kept whole so a report can show the command
    /// line the process was actually started with rather than a paraphrase.
    argv: []const []const u8,
    /// The one argument the shell appended, or null when the command line
    /// carries none. `launchArgumentFromArgv` decides, so the rule the report
    /// quotes and the rule the reader applied are the same one.
    argument: ?[]const u8,

    pub fn deinit(self: *ProcessCommandLine) void {
        for (self.argv) |entry| self.gpa.free(entry);
        self.gpa.free(self.argv);
        self.* = undefined;
    }
};

/// Read and split the command line THIS PROCESS WAS STARTED with.
///
/// Off Windows there is no command line the shell wrote and no process it
/// launched, so the door refuses by name instead of reporting that this
/// process was started with no entry.
pub fn processCommandLine(gpa: std.mem.Allocator) LaunchError!ProcessCommandLine {
    if (comptime !win.is_windows) return error.NotWindows;
    var count: c_int = 0;
    const raw = win.CommandLineToArgvW(win.GetCommandLineW(), &count) orelse
        return error.ShellRefused;
    defer _ = win.LocalFree(@ptrCast(raw));
    const total: usize = if (count < 1) 0 else @intCast(count);
    const argv = try gpa.alloc([]const u8, total);
    // The unwinding free walks only the entries that were filled, because an
    // unwritten slot holds no allocation and freeing one would be reading a
    // pointer this function never stored.
    var filled: usize = 0;
    errdefer {
        for (argv[0..filled]) |entry| gpa.free(entry);
        gpa.free(argv);
    }
    for (raw[0..total]) |source| {
        argv[filled] = try win.narrow(gpa, std.mem.span(source));
        filled += 1;
    }
    return .{
        .gpa = gpa,
        .argv = argv,
        .argument = launchArgumentFromArgv(argv),
    };
}

/// The activation one launch argument names, decoded against what this build
/// publishes.
///
/// The argument is matched against the published models rather than guessed
/// from its shape, because those models are what the shell was given: an
/// action name for a task and a path for a document, and nothing else. An
/// argument that names neither is `error.UnknownActivation` and one that names
/// both is `error.AmbiguousLaunchArgument`, and neither is resolved to
/// whichever happened to be matched first.
pub fn decodeLaunchArgument(
    argument: []const u8,
    tasks: []const JumpListTask,
    documents: []const RecentDocument,
) LaunchError!Activation {
    if (argument.len == 0) return error.UnknownActivation;
    var found: ?Activation = null;
    for (tasks) |task| {
        if (!std.mem.eql(u8, task.action_name, argument)) continue;
        if (found != null) return error.AmbiguousLaunchArgument;
        found = .{ .task = task.action_name };
    }
    for (documents) |document| {
        if (!std.mem.eql(u8, document.path, argument)) continue;
        if (found != null) return error.AmbiguousLaunchArgument;
        found = .{ .document = document.path };
    }
    return found orelse error.UnknownActivation;
}

/// One live window the jump list can reach.
///
/// The window is named by the core's own value-only handle, so a routing entry
/// cannot outlive its window without the generation in the handle disagreeing.
/// `owner` is the weak probe for the model behind that window, and `tree` and
/// `focus` are what the action registry resolves the action against.
pub const WindowRoute = struct {
    key: WindowHandle,
    /// The title the list shows for this window's task. An exact title match
    /// wins when two windows offer the same action, and an empty title means
    /// the window published no entry of its own and is reached by action name.
    title: []const u8 = "",
    /// The registered W10 action this window handles.
    action_name: []const u8,
    /// A JSON payload for that action. Null hands the action no payload, and a
    /// document selection supplies its own path instead.
    payload_json: ?[]const u8 = null,
    /// The document this window owns, so a document selection finds the same
    /// window a task with the same action would.
    document_path: ?[]const u8 = null,
    /// The action a DOCUMENT selection dispatches on this route, when the
    /// window opens its document with a different action from the one its jump
    /// list task runs.
    ///
    /// A document selection carries a path as its payload, and the action that
    /// accepts a path is frequently not the action the task runs. Null means
    /// the window does not distinguish them and a document selection
    /// dispatches `action_name`, which is the one-action window's own
    /// statement. It is a field and not a second route because the two entries
    /// belong to ONE window: two routes would leave `forget` holding half of
    /// it and would make a live count answer twice for one window.
    document_action_name: ?[]const u8 = null,
    owner: weak_owner.WeakOwner = .none(),
    tree: *const WidgetTree,
    focus: ?WidgetId = null,
};

/// One completed dispatch: which window ran it, and what the registry said.
pub const Dispatch = struct {
    window: WindowHandle,
    result: action.Result,
};

pub const RouteError = error{
    /// No window claims this selection.
    Unrouted,
    /// The window that claims it is gone. Its route has been dropped.
    WindowGone,
    /// Two live windows claim the same entry. A shell launch carries the
    /// action name or the path and no window, so two claimants are two answers
    /// and this refuses rather than picking one: handing an entry to a window
    /// the publisher did not name is the mistake this router exists to
    /// prevent.
    AmbiguousActivation,
} || std.mem.Allocator.Error;

/// The payload one dispatch carries, and who owns it.
const Payload = struct {
    json: ?[]const u8 = null,
    owned: ?[]u8 = null,

    fn deinit(self: *Payload, gpa: std.mem.Allocator) void {
        if (self.owned) |bytes| gpa.free(bytes);
        self.owned = null;
        self.json = null;
        self.* = undefined;
    }
};

/// Routes a selected jump list entry to the window that owns it.
pub const Router = struct {
    gpa: std.mem.Allocator,
    bridge: *menus.MenuActionBridge,
    routes: std.ArrayList(WindowRoute) = .empty,

    pub fn init(gpa: std.mem.Allocator, bridge: *menus.MenuActionBridge) Router {
        return .{ .gpa = gpa, .bridge = bridge };
    }

    pub fn deinit(self: *Router) void {
        self.routes.deinit(self.gpa);
        self.* = undefined;
    }

    /// Register a window. The route borrows every string and the tree, so all
    /// of them must outlive the router.
    pub fn addWindow(self: *Router, route: WindowRoute) !void {
        try self.routes.append(self.gpa, route);
    }

    /// Drop a window's route, and report whether there was one.
    pub fn forget(self: *Router, key: WindowHandle) bool {
        for (self.routes.items, 0..) |route, index| {
            if (!route.key.eql(key)) continue;
            _ = self.routes.swapRemove(index);
            return true;
        }
        return false;
    }

    /// The index of the window a selection names, or null when no window claims
    /// it.
    ///
    /// A task is routed by the title the list shows for it, because a list may
    /// hold one entry per window for the same action. The name-only pass exists
    /// for the windows that publish no title at all, and it skips every window
    /// that published a different one: handing a selection to a window that
    /// named a different title is how the action of a window that is gone ends
    /// up run against the window that happens to be left.
    ///
    /// Liveness is not consulted here. The target is chosen by identity, and
    /// `dispatch` then re-checks ownership, so a dead window is reported as gone
    /// and dropped rather than quietly served by its replacement.
    pub fn find(self: *const Router, selection: Selection) ?usize {
        switch (selection) {
            .document => |document| {
                for (self.routes.items, 0..) |route, index| {
                    const path = route.document_path orelse continue;
                    if (std.mem.eql(u8, path, document.path)) return index;
                }
                return null;
            },
            .task => |task| {
                for (self.routes.items, 0..) |route, index| {
                    if (!std.mem.eql(u8, route.action_name, task.action_name)) continue;
                    if (std.mem.eql(u8, route.title, task.title)) return index;
                }
                for (self.routes.items, 0..) |route, index| {
                    if (route.title.len != 0) continue;
                    if (std.mem.eql(u8, route.action_name, task.action_name)) return index;
                }
                return null;
            },
        }
    }

    /// The route a selection names, after its liveness re-check.
    ///
    /// A dead window is dropped rather than reported: its route is forgotten,
    /// so a second attempt names no window at all instead of running against a
    /// model the Session has already released.
    fn target(self: *Router, selection: Selection) RouteError!WindowRoute {
        const index = self.find(selection) orelse return error.Unrouted;
        const route = self.routes.items[index];
        if (!route.owner.isAlive()) {
            _ = self.routes.swapRemove(index);
            return error.WindowGone;
        }
        return route;
    }

    /// Route one selection to the window that owns it and dispatch it.
    ///
    /// The weak owner is re-checked after the target is chosen, and a dead
    /// window is dropped: its route is forgotten and the dispatch is reported
    /// as `error.WindowGone` rather than run against a model the Session has
    /// already released.
    ///
    /// The error set is `anyerror` and not `RouteError`, because the registry's
    /// dispatch is `anyerror`: an action handler is caller-supplied, so its
    /// failures are the model's own. A set that named only the routing refusals
    /// would have to flatten a handler that failed into `Unrouted`, which is a
    /// different thing from a window that claims nothing.
    pub fn dispatch(self: *Router, selection: Selection) anyerror!Dispatch {
        const route = try self.target(selection);
        var payload = try payloadFor(self.gpa, selection, route);
        defer payload.deinit(self.gpa);

        const item: menus.MenuItem = .{
            .label = route.title,
            .kind = .action,
            .action_name = actionFor(selection, route),
            .action_payload_json = payload.json,
        };
        const result = try self.bridge.dispatchItem(item, route.tree, route.focus);
        return .{ .window = route.key, .result = result };
    }

    /// Route one shell activation to the window that owns it.
    ///
    /// This is not the question `dispatch` answers. A selection the user made
    /// in a live list carries the title that list showed, so `find` can name
    /// one window out of several that handle the same action. A shell launch
    /// carries what the shim published and nothing else: an action name for a
    /// task, a path for a document. So the target is the one live window that
    /// claims that name, and two live windows that claim it are
    /// `error.AmbiguousActivation` rather than a coin toss. One name published
    /// as a task AND as a document is refused here too, because the decode that
    /// would have refused it is a convention and this is the boundary.
    ///
    /// The dead are dropped first, exactly as `dispatch` drops them: a launch
    /// names a window by what it published rather than by identity, so a route
    /// whose weak owner has gone is forgotten here and the next attempt at the
    /// same entry names no window at all. What `prune` dropped is remembered,
    /// because a launch that found the window it names and no longer has it is
    /// `error.WindowGone` and a launch that found no window at all is
    /// `error.Unrouted`, and those are different answers about the desktop.
    ///
    /// The selection handed to `dispatch` is built from the ROUTE, not from the
    /// argument, so the title it matches and the path the action receives as
    /// its payload are the ones this window published. A document launch
    /// therefore carries the same payload a list selection would, and both go
    /// through one dispatch.
    pub fn activate(self: *Router, activation: Activation) anyerror!Dispatch {
        const dead_claims = self.prune(activation);
        if (namesBothKinds(self.routes.items, activation)) return error.AmbiguousActivation;
        var claim: ?usize = null;
        for (self.routes.items, 0..) |route, index| {
            if (!claims(route, activation)) continue;
            if (claim != null) return error.AmbiguousActivation;
            claim = index;
        }
        const index = claim orelse return if (dead_claims != 0)
            error.WindowGone
        else
            error.Unrouted;
        const route = self.routes.items[index];
        const selection: Selection = switch (activation) {
            .task => .{ .task = .{
                .title = route.title,
                .action_name = route.action_name,
            } },
            .document => .{ .document = .{ .path = route.document_path.? } },
        };
        return self.dispatch(selection);
    }

    /// Drop every route whose window has gone, and report how many of them
    /// THIS ACTIVATION had named.
    ///
    /// Swapped out rather than erased so the surviving routes keep their
    /// relative order, and the loop continues at the same index because the
    /// route that took this one's place has not been looked at yet.
    fn prune(self: *Router, activation: Activation) usize {
        var named: usize = 0;
        var index: usize = 0;
        while (index < self.routes.items.len) {
            const route = self.routes.items[index];
            if (route.owner.isAlive()) {
                index += 1;
                continue;
            }
            _ = self.routes.swapRemove(index);
            if (claims(route, activation)) named += 1;
        }
        return named;
    }
};

/// Whether this route publishes the entry one activation named.
fn claims(route: WindowRoute, activation: Activation) bool {
    return switch (activation) {
        .task => |name| std.mem.eql(u8, route.action_name, name),
        .document => |path| if (route.document_path) |owned|
            std.mem.eql(u8, owned, path)
        else
            false,
    };
}

/// Whether the live routes publish ONE activation under both a task's action
/// name and a document's path.
///
/// `decodeLaunchArgument` refuses that argument against the published models,
/// and that refusal is what keeps a shell launch from having two answers. It is
/// also a convention: `Activation` is a plain string union, so any caller can
/// write `.{ .task = path }` and skip the decode entirely. The router is the
/// last thing between an argument and a live dispatch, so it repeats the rule
/// against the only models it holds. A collision among routes is a collision
/// among published entries, and it has two answers whichever models it is
/// checked against.
///
/// It runs after `prune`, so a window that has gone cannot manufacture an
/// ambiguity out of an entry the desktop no longer has.
fn namesBothKinds(routes: []const WindowRoute, activation: Activation) bool {
    var as_task = false;
    var as_document = false;
    const name = switch (activation) {
        .task => |task| task,
        .document => |document| document,
    };
    for (routes) |route| {
        if (std.mem.eql(u8, route.action_name, name)) as_task = true;
        if (route.document_path) |owned| {
            if (std.mem.eql(u8, owned, name)) as_document = true;
        }
    }
    return as_task and as_document;
}

/// What one window model recorded.
const Observed = struct {
    opened: usize = 0,
    reloaded: usize = 0,
    path: []const u8 = &.{},
};

/// Read one window model's record back out of the Session.
///
/// The model data lives in the Session and not in the handle, so a test that
/// looked at the handle would be reading a key and a ticket. The returned path
/// borrows the Session's own storage and stays valid while the model is live.
fn observe(session: *nogui.Session, model: nogui.WeakModel(WindowModel)) !Observed {
    const Read = struct {
        fn run(value: *const WindowModel, out: *Observed) void {
            out.* = .{
                .opened = value.opened,
                .reloaded = value.reloaded,
                .path = value.lastPath(),
            };
        }
    };
    var out: Observed = .{};
    try session.read(WindowModel, model, &out, Read.run);
    return out;
}

/// The payload one dispatch hands the registry.
///
/// A route's own payload wins, because a route is the more specific statement
/// of what that window wants. Otherwise a document selection carries its own
/// path and a task selection carries nothing.
fn payloadFor(
    gpa: std.mem.Allocator,
    selection: Selection,
    route: WindowRoute,
) !Payload {
    if (route.payload_json) |json| return .{ .json = json };
    return switch (selection) {
        .task => .{},
        .document => |document| blk: {
            const encoded = try jsonDocument(gpa, document.path);
            break :blk .{ .json = encoded, .owned = encoded };
        },
    };
}

/// The action one selection dispatches on this route.
///
/// A task selection runs the action the window's jump list entry names. A
/// document selection runs the action the window declared for its document,
/// because that action is the one registered with a path payload; a window
/// that named none has one action for both, and that action is what the
/// document selection dispatches.
fn actionFor(selection: Selection, route: WindowRoute) []const u8 {
    return switch (selection) {
        .task => route.action_name,
        .document => route.document_action_name orelse route.action_name,
    };
}

/// The JSON payload one document selection hands the registry.
///
/// It is an OBJECT with a `path` field, because the action that opens a
/// document declares its payload as a named field and the registry rejects a
/// bare string against such a schema. A bare string would satisfy an action
/// whose whole payload is a string and be refused by one whose payload is
/// `{ path }`, and the router cannot know which of the two it is dispatching
/// against -- so it writes the shape the shared recent-document model is: a
/// path, under the name it has.
///
/// The registry parses the payload, and a Windows path is full of
/// backslashes, so the escaping is not optional: a raw path would parse as a
/// run of escapes and the action would receive a different string than the one
/// the user chose.
fn jsonDocument(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "{\"path\":\"");
    for (path) |byte| {
        switch (byte) {
            '"' => try out.appendSlice(gpa, "\\\""),
            '\\' => try out.appendSlice(gpa, "\\\\"),
            0x08 => try out.appendSlice(gpa, "\\b"),
            0x0C => try out.appendSlice(gpa, "\\f"),
            '\n' => try out.appendSlice(gpa, "\\n"),
            '\r' => try out.appendSlice(gpa, "\\r"),
            '\t' => try out.appendSlice(gpa, "\\t"),
            else => {
                if (byte < 0x20) {
                    var escape: [6]u8 = undefined;
                    _ = try std.fmt.bufPrint(&escape, "\\u{x:0>4}", .{byte});
                    try out.appendSlice(gpa, &escape);
                } else {
                    try out.append(gpa, byte);
                }
            },
        }
    }
    try out.appendSlice(gpa, "\"}");
    return out.toOwnedSlice(gpa);
}

// --- tests ------------------------------------------------------------------

/// The payload the action that opens a document declares: a named `path`
/// field, which is what `jsonDocument` writes and what this module's document
/// route is built to carry.
const OpenPayload = struct { path: []const u8 };
const OpenAction = action.Action(OpenPayload, "file.open");
const ReloadAction = action.Action(void, "view.reload");

/// The model behind one window. It is what the registry dispatches into, so a
/// test can tell which window a selection reached.
///
/// The payload is borrowed for the length of the call, so the model copies it
/// into its own storage rather than keeping the caller's pointer. A test that
/// read it afterwards would be reading a buffer the router has already freed.
const WindowModel = struct {
    const Self = WindowModel;

    /// Long enough for every path a test routes, and fixed so a payload can
    /// never outlive the model that received it.
    const path_capacity = 64;

    opened: usize = 0,
    reloaded: usize = 0,
    path_buffer: [path_capacity]u8,
    path_len: usize = 0,

    fn open(self: *Self, payload: *const OpenPayload, _: *nogui.Session) !void {
        self.opened += 1;
        const path = payload.path;
        self.path_len = @min(path.len, self.path_buffer.len);
        @memcpy(self.path_buffer[0..self.path_len], path[0..self.path_len]);
    }

    fn lastPath(self: *const Self) []const u8 {
        return self.path_buffer[0..self.path_len];
    }

    fn openAvailable(self: *const Self, _: *nogui.Session) action.Availability {
        _ = self;
        return .available;
    }

    fn reload(self: *Self, _: *const void, _: *nogui.Session) !void {
        self.reloaded += 1;
    }

    fn reloadAvailable(self: *const Self, _: *nogui.Session) action.Availability {
        _ = self;
        return .available;
    }
};

/// The weak probe the router re-checks. The registry's own binding is weak
/// too, but the router's decision has to be observable on its own, so a test
/// owns the flag and the router reads it through this probe.
const Owner = struct {
    alive: bool = true,

    fn probe(context: *const anyopaque) bool {
        const self: *const Owner = @ptrCast(@alignCast(context));
        return self.alive;
    }

    fn bind(self: *const Owner) weak_owner.WeakOwner {
        return .{ .context = self, .is_alive_fn = Owner.probe };
    }
};

/// The UTF-8 form of one widened string, for a test that states the value the
/// shell will see.
fn utf8Of(gpa: std.mem.Allocator, wide: [:0]const u16) ![]u8 {
    return std.unicode.utf16LeToUtf8Alloc(gpa, wide);
}

test "api-w23 jump list refuses a process with no identity of its own" {
    // No declared identity: there is nothing to name a list after.
    try std.testing.expectError(error.IdentityUnset, identityAdmits(null, null));
    try std.testing.expectError(error.IdentityUnset, identityAdmits(null, "com.7games.nogui"));

    // A declared identity and no explicit process identity is the case the
    // shell would file under the executable path instead.
    try std.testing.expectError(error.IdentityUnset, identityAdmits("com.7games.nogui", null));

    // A malformed identity is the app's own string to fix, so it is named
    // apart from a process that simply holds a different one.
    try std.testing.expectError(
        error.IdentityMalformed,
        identityAdmits("com..7games", "com.7games"),
    );

    // The process holds an identity that is not the one the app declared.
    try std.testing.expectError(
        error.IdentityMismatch,
        identityAdmits("com.7games.nogui", "com.7games.other"),
    );

    try identityAdmits("com.7games.nogui", "com.7games.nogui");
}

test "api-w23 jump list publish is refused off windows" {
    // A build with no Windows shell has no list to publish into, and it says so
    // by name rather than reporting a success nobody could check.
    if (comptime !win.is_windows) {
        var list = JumpList.init(std.testing.allocator);
        defer list.deinit();
        try std.testing.expect(list.identityName() == null);
        try std.testing.expectError(error.NotWindows, list.publish());
        try std.testing.expect(!is_windows);
    }
}

test "api-w23 jump list model widens the shared task and document types" {
    const gpa = std.testing.allocator;
    var list = JumpList.init(gpa);
    defer list.deinit();

    const tasks = [_]JumpListTask{
        .{ .title = "New", .action_name = "file.new" },
        .{
            .title = "Reload",
            .action_name = "view.reload",
            .description = "Reload the open document",
        },
    };
    const documents = [_]RecentDocument{
        .{ .path = "C:\\docs\\one.txt" },
        .{ .path = "C:\\docs\\two.txt", .display_name = "two" },
    };
    list.setJumpListTasks(&tasks);
    list.setRecentDocuments(&documents);

    var model = try list.build();
    defer model.deinit();

    try std.testing.expectEqual(@as(usize, 2), model.tasks.len);
    const first_action = try utf8Of(gpa, model.tasks[0].action_name);
    defer gpa.free(first_action);
    try std.testing.expectEqualStrings("file.new", first_action);
    try std.testing.expect(model.tasks[0].description == null);
    try std.testing.expect(model.tasks[1].description != null);

    try std.testing.expectEqual(@as(usize, 2), model.documents.len);
    const first_path = try utf8Of(gpa, model.documents[0].path);
    defer gpa.free(first_path);
    try std.testing.expectEqualStrings("C:\\docs\\one.txt", first_path);
    try std.testing.expect(model.documents[0].display_name == null);
    try std.testing.expect(model.documents[1].display_name != null);

    // An entry that names nothing is refused instead of published blank.
    const blank_tasks = [_]JumpListTask{.{ .title = "", .action_name = "file.new" }};
    const blank_documents = [_]RecentDocument{.{ .path = "" }};
    list.setJumpListTasks(&blank_tasks);
    list.setRecentDocuments(&documents);
    try std.testing.expectError(error.InvalidEntry, list.build());

    list.setJumpListTasks(&tasks);
    list.setRecentDocuments(&blank_documents);
    try std.testing.expectError(error.InvalidEntry, list.build());
}

test "api-w23 router reaches the window that claims the action" {
    const gpa = std.testing.allocator;
    var session = try nogui.Session.init(gpa);
    defer session.deinit() catch unreachable;
    var registry = try action.Registry.init(gpa, &session);
    defer registry.deinit();
    try registry.register(OpenAction);
    try registry.register(ReloadAction);

    // SAFETY: the buffer is read only up to `path_len`, which starts at zero,
    // and `open` fills the bytes before any read past it.
    var initial: WindowModel = .{ .path_buffer = undefined };
    var notes = try session.create(WindowModel, &initial);
    defer session.release(WindowModel, &notes) catch unreachable;
    // SAFETY: the buffer is read only up to `path_len`, which starts at zero,
    // and `open` fills the bytes before any read past it.
    var log_initial: WindowModel = .{ .path_buffer = undefined };
    var log = try session.create(WindowModel, &log_initial);
    defer session.release(WindowModel, &log) catch unreachable;

    const widget: WidgetId = .{ .owner = 1, .slot = 10, .generation = 1 };
    _ = try registry.bind(
        OpenAction,
        WindowModel,
        WindowModel.open,
        WindowModel.openAvailable,
        .{ .widget = widget },
        notes.weak(),
    );
    _ = try registry.bind(
        ReloadAction,
        WindowModel,
        WindowModel.reload,
        WindowModel.reloadAvailable,
        .{ .widget = widget },
        log.weak(),
    );

    var tree = WidgetTree.init(gpa);
    defer tree.deinit();
    try tree.nodes.append(gpa, .{
        .id = @enumFromInt(1),
        .widget_id = widget,
        .parent = .root,
        .kind = .{ .label = .{ .text = "child" } },
    });

    const notes_key: WindowHandle = .{
        .host = 1,
        .slot = 0,
        .generation = 1,
        .session_window = 11,
    };
    const log_key: WindowHandle = .{
        .host = 1,
        .slot = 1,
        .generation = 1,
        .session_window = 12,
    };

    var owner: Owner = .{ .alive = true };
    var bridge = menus.MenuActionBridge.init(&registry);
    var router = Router.init(gpa, &bridge);
    defer router.deinit();
    try router.addWindow(.{
        .key = notes_key,
        .title = "Notes",
        .action_name = OpenAction.name,
        .document_path = "C:\\docs\\one.txt",
        .owner = owner.bind(),
        .tree = &tree,
        .focus = widget,
    });
    try router.addWindow(.{
        .key = log_key,
        .title = "Log",
        .action_name = ReloadAction.name,
        .owner = owner.bind(),
        .tree = &tree,
        .focus = widget,
    });

    // A document selection reaches the window that owns that document, and the
    // path reaches the action as its payload.
    const document = try router.dispatch(.{ .document = .{ .path = "C:\\docs\\one.txt" } });
    try std.testing.expect(document.window.eql(notes_key));
    try std.testing.expectEqual(action.Result.handled, document.result);
    const after_document = try observe(&session, notes.weak());
    try std.testing.expectEqual(@as(usize, 1), after_document.opened);
    try std.testing.expectEqualStrings("C:\\docs\\one.txt", after_document.path);
    const log_after_document = try observe(&session, log.weak());
    try std.testing.expectEqual(@as(usize, 0), log_after_document.reloaded);

    // A task selection reaches the other window, and each action went to the
    // model that registered it.
    const task = try router.dispatch(.{ .task = .{
        .title = "Log",
        .action_name = ReloadAction.name,
    } });
    try std.testing.expect(task.window.eql(log_key));
    try std.testing.expectEqual(action.Result.handled, task.result);
    const log_after_task = try observe(&session, log.weak());
    try std.testing.expectEqual(@as(usize, 1), log_after_task.reloaded);
    const notes_after_task = try observe(&session, notes.weak());
    try std.testing.expectEqual(@as(usize, 1), notes_after_task.opened);

    // A document no window claims is unrouted, and it runs nothing.
    try std.testing.expectError(error.Unrouted, router.dispatch(.{ .document = .{
        .path = "C:\\docs\\missing.txt",
    } }));
    try std.testing.expectError(
        error.Unrouted,
        router.dispatch(.{ .task = .{ .title = "Nowhere", .action_name = "file.absent" } }),
    );
    const notes_after_unrouted = try observe(&session, notes.weak());
    try std.testing.expectEqual(@as(usize, 1), notes_after_unrouted.opened);
    const log_after_unrouted = try observe(&session, log.weak());
    try std.testing.expectEqual(@as(usize, 1), log_after_unrouted.reloaded);

    // The re-check is live, not a copy taken at registration: a window that
    // goes away after the routes were built is dropped on the next selection.
    owner.alive = false;
    try std.testing.expectError(error.WindowGone, router.dispatch(.{ .document = .{
        .path = "C:\\docs\\one.txt",
    } }));
    const notes_after_death = try observe(&session, notes.weak());
    try std.testing.expectEqual(@as(usize, 1), notes_after_death.opened);
}

test "api-w23 a dead window is dropped and never handed to another" {
    const gpa = std.testing.allocator;
    var session = try nogui.Session.init(gpa);
    defer session.deinit() catch unreachable;
    var registry = try action.Registry.init(gpa, &session);
    defer registry.deinit();
    try registry.register(ReloadAction);

    // SAFETY: the buffer is read only up to `path_len`, which starts at zero,
    // and `open` fills the bytes before any read past it.
    var initial: WindowModel = .{ .path_buffer = undefined };
    var model = try session.create(WindowModel, &initial);
    defer session.release(WindowModel, &model) catch unreachable;

    const widget: WidgetId = .{ .owner = 1, .slot = 10, .generation = 1 };
    _ = try registry.bind(
        ReloadAction,
        WindowModel,
        WindowModel.reload,
        WindowModel.reloadAvailable,
        .{ .widget = widget },
        model.weak(),
    );

    var tree = WidgetTree.init(gpa);
    defer tree.deinit();
    try tree.nodes.append(gpa, .{
        .id = @enumFromInt(1),
        .widget_id = widget,
        .parent = .root,
        .kind = .{ .label = .{ .text = "child" } },
    });

    const dead_key: WindowHandle = .{
        .host = 1,
        .slot = 0,
        .generation = 1,
        .session_window = 11,
    };
    const live_key: WindowHandle = .{
        .host = 1,
        .slot = 1,
        .generation = 1,
        .session_window = 12,
    };

    var dead_owner: Owner = .{ .alive = true };
    const live_owner: Owner = .{ .alive = true };
    var bridge = menus.MenuActionBridge.init(&registry);
    var router = Router.init(gpa, &bridge);
    defer router.deinit();
    // Both windows offer the same action, so a fall-through would be visible:
    // the live window would answer for the dead one.
    try router.addWindow(.{
        .key = dead_key,
        .title = "Dead",
        .action_name = ReloadAction.name,
        .owner = dead_owner.bind(),
        .tree = &tree,
        .focus = widget,
    });
    try router.addWindow(.{
        .key = live_key,
        .title = "Live",
        .action_name = ReloadAction.name,
        .owner = live_owner.bind(),
        .tree = &tree,
        .focus = widget,
    });

    dead_owner.alive = false;
    const dead_selection: Selection = .{ .task = .{
        .title = "Dead",
        .action_name = ReloadAction.name,
    } };
    try std.testing.expectError(error.WindowGone, router.dispatch(dead_selection));
    // The dead window ran nothing, and the live one did not answer for it.
    const after_death = try observe(&session, model.weak());
    try std.testing.expectEqual(@as(usize, 0), after_death.reloaded);
    // Its route is gone, so the same selection is now unrouted rather than
    // served by the window that happens to be left.
    try std.testing.expect(router.find(dead_selection) == null);
    try std.testing.expectError(error.Unrouted, router.dispatch(dead_selection));
    const after_drop = try observe(&session, model.weak());
    try std.testing.expectEqual(@as(usize, 0), after_drop.reloaded);

    const live = try router.dispatch(.{ .task = .{
        .title = "Live",
        .action_name = ReloadAction.name,
    } });
    try std.testing.expect(live.window.eql(live_key));
    const after_live = try observe(&session, model.weak());
    try std.testing.expectEqual(@as(usize, 1), after_live.reloaded);

    // `forget` is the host's own path for a window that has gone, and it drops
    // exactly one route.
    try std.testing.expect(router.forget(live_key));
    try std.testing.expect(!router.forget(live_key));
    try std.testing.expect(router.routes.items.len == 0);
    try std.testing.expectError(
        error.Unrouted,
        router.dispatch(.{ .task = .{ .title = "Live", .action_name = ReloadAction.name } }),
    );
    const after_forget = try observe(&session, model.weak());
    try std.testing.expectEqual(@as(usize, 1), after_forget.reloaded);
}

test "api-w23 a document path is escaped into the payload it is" {
    // The registry parses the payload, so an unescaped Windows path would hand
    // the action a different string than the one the user chose, and a bare
    // string instead of a `path` field would be refused by the schema before
    // the string was ever read.
    const gpa = std.testing.allocator;
    const escaped = try jsonDocument(gpa, "C:\\docs\\a\"b.txt");
    defer gpa.free(escaped);
    try std.testing.expectEqualStrings("{\"path\":\"C:\\\\docs\\\\a\\\"b.txt\"}", escaped);

    const control = try jsonDocument(gpa, "a\x01b");
    defer gpa.free(control);
    try std.testing.expectEqualStrings("{\"path\":\"a\\u0001b\"}", control);

    const plain = try jsonDocument(gpa, "notes.txt");
    defer gpa.free(plain);
    try std.testing.expectEqualStrings("{\"path\":\"notes.txt\"}", plain);
}

test "api-w23 a launch argument is decoded against what was published" {
    // The shim gives a task link its action name as the argument list and
    // records a document under its own path, so those two exact strings are
    // all a shell-launched entry can be. Anything else belongs to whoever
    // typed it, and decoding it would route an entry the publisher never made.
    const tasks = [_]JumpListTask{
        .{ .title = "New", .action_name = "file.new" },
        .{ .title = "Reload", .action_name = "view.reload" },
    };
    const documents = [_]RecentDocument{
        .{ .path = "C:\\docs\\one.txt" },
        .{ .path = "C:\\docs\\two.txt" },
    };

    const task = try decodeLaunchArgument("view.reload", &tasks, &documents);
    try std.testing.expectEqualStrings("view.reload", task.task);
    const document = try decodeLaunchArgument("C:\\docs\\two.txt", &tasks, &documents);
    try std.testing.expectEqualStrings("C:\\docs\\two.txt", document.document);

    // An argument that names nothing published, and an empty one, are the same
    // answer: this process was not launched from the list.
    try std.testing.expectError(
        error.UnknownActivation,
        decodeLaunchArgument("--frames", &tasks, &documents),
    );
    try std.testing.expectError(
        error.UnknownActivation,
        decodeLaunchArgument("", &tasks, &documents),
    );
    // The executable's own path is not an entry, however it was spelled.
    try std.testing.expectError(
        error.UnknownActivation,
        decodeLaunchArgument("w23-windows-smoke.exe", &tasks, &documents),
    );

    // An argument that is both a task's action name and a document's path has
    // two answers, and picking one would be a guess about which list the person
    // who chose it was looking at.
    const colliding_tasks = [_]JumpListTask{.{ .title = "Odd", .action_name = "C:\\docs\\one.txt" }};
    try std.testing.expectError(
        error.AmbiguousLaunchArgument,
        decodeLaunchArgument("C:\\docs\\one.txt", &colliding_tasks, &documents),
    );
}

test "api-w23 a launch is this executable's one argument and nothing else" {
    // The rule the shell writes to, stated over the argument vector itself:
    // an entry arrives alone. A longer line was typed by a person, and a
    // person typing flags has not handed this process an entry.
    const exe = "w23-windows-smoke.exe";
    try std.testing.expectEqualStrings(
        "w23.add_row",
        launchArgumentFromArgv(&.{ exe, "w23.add_row" }).?,
    );
    try std.testing.expectEqualStrings(
        "C:\\docs\\two.txt",
        launchArgumentFromArgv(&.{ exe, "C:\\docs\\two.txt" }).?,
    );

    // The executable alone, the executable with a command and its approvals,
    // and the executable with an argument and something after it, are all a
    // person's line.
    try std.testing.expect(launchArgumentFromArgv(&.{exe}) == null);
    try std.testing.expect(launchArgumentFromArgv(&.{}) == null);
    try std.testing.expect(
        launchArgumentFromArgv(&.{ exe, "jumplist", "--authorize-jump-list-publish" }) == null,
    );
    try std.testing.expect(launchArgumentFromArgv(&.{ exe, "w23.add_row", "and-more" }) == null);
}

test "api-w23 the launch door is a named refusal off windows" {
    // Off Windows there is no command line the shell wrote and no process the
    // shell launched, so the door refuses by name instead of reporting that
    // this process was started with no entry.
    if (comptime !win.is_windows) {
        try std.testing.expectError(
            error.NotWindows,
            processCommandLine(std.testing.allocator),
        );
    }
}

test "api-w23 a shell launch reaches the window that published the entry" {
    const gpa = std.testing.allocator;
    var session = try nogui.Session.init(gpa);
    defer session.deinit() catch unreachable;
    var registry = try action.Registry.init(gpa, &session);
    defer registry.deinit();
    try registry.register(OpenAction);
    try registry.register(ReloadAction);

    // SAFETY: the buffer is read only up to `path_len`, which starts at zero,
    // and `open` fills the bytes before any read past it.
    var initial: WindowModel = .{ .path_buffer = undefined };
    var model = try session.create(WindowModel, &initial);
    defer session.release(WindowModel, &model) catch unreachable;

    const widget: WidgetId = .{ .owner = 1, .slot = 10, .generation = 1 };
    _ = try registry.bind(
        OpenAction,
        WindowModel,
        WindowModel.open,
        WindowModel.openAvailable,
        .{ .widget = widget },
        model.weak(),
    );
    _ = try registry.bind(
        ReloadAction,
        WindowModel,
        WindowModel.reload,
        WindowModel.reloadAvailable,
        .{ .widget = widget },
        model.weak(),
    );

    var tree = WidgetTree.init(gpa);
    defer tree.deinit();
    try tree.nodes.append(gpa, .{
        .id = @enumFromInt(1),
        .widget_id = widget,
        .parent = .root,
        .kind = .{ .label = .{ .text = "child" } },
    });

    const key: WindowHandle = .{
        .host = 1,
        .slot = 0,
        .generation = 1,
        .session_window = 11,
    };
    const other_key: WindowHandle = .{
        .host = 1,
        .slot = 1,
        .generation = 1,
        .session_window = 12,
    };

    var owner: Owner = .{ .alive = true };
    var other_owner: Owner = .{ .alive = true };
    var bridge = menus.MenuActionBridge.init(&registry);
    var router = Router.init(gpa, &bridge);
    defer router.deinit();
    // ONE window with two entries: the task runs the action that takes no
    // payload, and the document runs the action that takes the path.
    try router.addWindow(.{
        .key = key,
        .title = "Notes",
        .action_name = ReloadAction.name,
        .document_action_name = OpenAction.name,
        .document_path = "C:\\docs\\one.txt",
        .owner = owner.bind(),
        .tree = &tree,
        .focus = widget,
    });

    // A task launch carries the action name the shim put in the link's
    // argument list, and nothing else, so it reaches the window that handles
    // that action through the same registry and the same model a list
    // selection would. It carries NO payload, so the action it runs is one
    // that declares none: a payload-carrying action has nothing to be given.
    const task = try router.activate(.{ .task = ReloadAction.name });
    try std.testing.expect(task.window.eql(key));
    try std.testing.expectEqual(action.Result.handled, task.result);
    const after_task = try observe(&session, model.weak());
    try std.testing.expectEqual(@as(usize, 1), after_task.reloaded);
    try std.testing.expectEqual(@as(usize, 0), after_task.opened);

    // A document launch carries the path, and the payload the action receives
    // is that path rather than the title a list selection would have carried.
    const document = try router.activate(.{ .document = "C:\\docs\\one.txt" });
    try std.testing.expect(document.window.eql(key));
    const after_document = try observe(&session, model.weak());
    try std.testing.expectEqual(@as(usize, 1), after_document.opened);
    try std.testing.expectEqualStrings("C:\\docs\\one.txt", after_document.path);

    // An entry no window claims is unrouted, and it runs nothing.
    try std.testing.expectError(error.Unrouted, router.activate(.{ .task = "file.absent" }));
    try std.testing.expectError(
        error.Unrouted,
        router.activate(.{ .document = "C:\\docs\\absent.txt" }),
    );
    const after_unrouted = try observe(&session, model.weak());
    try std.testing.expectEqual(@as(usize, 1), after_unrouted.opened);
    try std.testing.expectEqual(@as(usize, 1), after_unrouted.reloaded);

    // A second window that handles the same action makes the task launch
    // ambiguous, and an ambiguous launch is refused rather than sent to one of
    // them: the shell named the action, not the window. The document launch
    // stays unambiguous, because the second window published no document.
    try router.addWindow(.{
        .key = other_key,
        .title = "Other",
        .action_name = ReloadAction.name,
        .owner = other_owner.bind(),
        .tree = &tree,
        .focus = widget,
    });
    try std.testing.expectError(
        error.AmbiguousActivation,
        router.activate(.{ .task = ReloadAction.name }),
    );
    _ = try router.activate(.{ .document = "C:\\docs\\one.txt" });
    const after_unambiguous = try observe(&session, model.weak());
    try std.testing.expectEqual(@as(usize, 2), after_unambiguous.opened);

    // A window that has gone is dropped before the name is matched, so the
    // same launch reaches the one window that is left and the dead route is
    // gone rather than remembered.
    other_owner.alive = false;
    const after_death = try router.activate(.{ .task = ReloadAction.name });
    try std.testing.expect(after_death.window.eql(key));
    try std.testing.expectEqual(@as(usize, 1), router.routes.items.len);

    // When the LAST window that claimed it is gone as well, the launch named a
    // window this desktop no longer has. That is a different answer from one
    // that named no window at all, and it is reported as its own name.
    owner.alive = false;
    try std.testing.expectError(
        error.WindowGone,
        router.activate(.{ .task = ReloadAction.name }),
    );
    try std.testing.expectEqual(@as(usize, 0), router.routes.items.len);
}
