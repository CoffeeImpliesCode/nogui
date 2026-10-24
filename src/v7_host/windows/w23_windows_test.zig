//! W23 Windows adapter tests.
//!
//! Every test here is deterministic and needs no Windows: it exercises the
//! parts of the E03 adapters that are platform-neutral in shape -- the identity
//! grammar, the credential target-name derivation, the toast activation
//! encoding, the capture request narrowing, the menu's command numbering and
//! the jump list's launch door -- so a Linux `zig build test` can still tell
//! whether those parts are right.
//!
//! What it cannot tell is whether Windows accepts any of it. No test in this
//! file claims runtime proof for Windows, because a Linux run cannot produce
//! any. The Windows acceptance for E03 is a run on Windows: an identity that
//! groups the app, a jump-list action that reaches the right window, a credential
//! that round-trips through the Windows store, a toast whose action arrives
//! through the COM activator, and a capture that delivers owned CPU frames after
//! the user approved a target in the system picker.
const std = @import("std");

const app_identity = @import("app_identity.zig");
const capture = @import("capture.zig");
const credentials = @import("credentials.zig");
const menus = @import("menus.zig");
const notifications = @import("notifications.zig");
const root = @import("root.zig");
const jump_list = @import("jump_list.zig");
const window_interop = @import("window_interop.zig");

const nogui = @import("nogui");
const weak_owner = @import("../weak_owner.zig");

// The adapters keep their contract types private, because the contracts have
// exactly one declaration and it is the shared one. A test that reads a
// contract name reads it from there rather than through an adapter's alias.
const shared_capture = @import("../capture.zig");
const shared_credentials = @import("../credentials.zig");
const shared_menus = @import("../menus.zig");
const shared_notifications = @import("../notifications.zig");

// Referenced so the test artifact includes their inline tests. The host's test
// block reaches this file, and this file reaches every adapter.
comptime {
    _ = app_identity;
    _ = capture;
    _ = credentials;
    _ = menus;
    _ = notifications;
    _ = root;
    _ = jump_list;
    _ = window_interop;
    _ = shared_capture;
    _ = shared_credentials;
    _ = shared_notifications;
    _ = shared_menus;
    _ = weak_owner;
}

test "api-w23 a toast action key routes to the notification that offered it" {
    // The same action key in two live notifications must not be confused. The
    // activation argument is the only thing the shell hands back, so the
    // identifier has to travel inside it.
    const gpa = std.testing.allocator;
    const first = try notifications.encodeArgument(gpa, 11, "reply");
    defer gpa.free(first);
    const second = try notifications.encodeArgument(gpa, 12, "reply");
    defer gpa.free(second);

    const a = notifications.decodeArgument(first).?;
    const b = notifications.decodeArgument(second).?;
    try std.testing.expectEqual(@as(shared_notifications.NotificationId, 11), a.id);
    try std.testing.expectEqual(@as(shared_notifications.NotificationId, 12), b.id);
    try std.testing.expectEqualStrings(a.key, b.key);
    try std.testing.expect(!std.mem.eql(u8, first, second));
}

test "api-w23 windows adapters claim nothing on a target that has no windows" {
    // The single most important property of this directory off Windows: nothing
    // claims a capability it cannot back, and nothing returns a plausible answer
    // in place of a platform refusal.
    if (comptime !root.isApplicable()) {
        const gpa = std.testing.allocator;

        // Notifications: no capabilities, every submit unsupported, and a
        // dismissal named `unsupported` rather than a refusal from a shell
        // that is not there.
        const provider = try notifications.Provider.init(
            gpa,
            std.testing.io,
            .{ .app_id = "com.7games.nogui" },
        );
        defer provider.deinit();
        const handle = provider.provider();
        try std.testing.expectEqual(shared_notifications.Capabilities.none, handle.getCapabilities());
        try std.testing.expectEqual(
            shared_notifications.SubmitOutcome.unsupported,
            handle.submit(.{ .summary = "hello" }),
        );
        try std.testing.expectEqual(
            shared_notifications.DismissOutcome.unsupported,
            handle.dismiss(1),
        );

        // Credentials: a store that is not there is `unsupported`, not a `not_found`
        // that would read as an empty keyring.
        const creds = try credentials.Provider.init(gpa, .{});
        defer creds.deinit();
        const cred_handle = creds.provider();
        const query: shared_credentials.CredentialQuery = .{ .service = "s", .account = "a" };
        try std.testing.expectEqual(
            shared_credentials.ReadResult.unsupported,
            cred_handle.read(gpa, query, null),
        );

        // Capture: a machine with no picker is not a machine whose capture the
        // user declined, and the two must not share a state.
        const caps = capture.capabilities();
        try std.testing.expect(!caps.available);
        try std.testing.expect(caps.unavailable_reason.len != 0);

        // Menus: no global menu bar, and no in-app bar pretending to be one.
        try std.testing.expect(!menus.hasNativeGlobalMenu());

        // Identity: nothing was claimed, so nothing reports one.
        try std.testing.expect((try app_identity.currentProcessIdentity(gpa)) == null);
    }
}

test "api-w23 windows capture never reports a stream it did not get approval for" {
    // The capture path has exactly one way to obtain a target, and it is the
    // platform's own picker. A request the picker cannot honour is refused by
    // name rather than answered with the nearest thing it can do, because a
    // caller that believes it captured what it asked for is worse off than one
    // that was told no.
    try std.testing.expectError(
        error.UnsupportedSources,
        capture.validate(.{ .sources = shared_capture.SourceType.virtual }),
    );
    try std.testing.expectError(
        error.MultipleStreamsUnsupported,
        capture.validate(.{ .multiple = true }),
    );
    try std.testing.expectError(
        error.UnsupportedPersistence,
        capture.validate(.{ .persistence = .until_revoked }),
    );
}

// ── the jump list's launch door ──────────────────────
// ───────────────────────

/// The one widget both door actions are bound to, so a dispatch has to resolve
/// the action against a node that exists.
const door_widget: nogui.WidgetId = .{ .owner = 1, .slot = 10, .generation = 1 };

const DoorPayload = struct { path: []const u8 };
const door_reload = nogui.action.Action(void, "w23.door_reload");
const door_open = nogui.action.Action(DoorPayload, "w23.door_open");

/// The model behind the door's window. Two actions, so a test can tell which
/// one a launch reached, and nothing kept, so nothing here outlives the call
/// that handed it over.
const DoorModel = struct {
    reloaded: usize = 0,
    opened: usize = 0,

    fn reload(self: *DoorModel, _: *const void, _: *nogui.Session) !void {
        self.reloaded += 1;
    }

    fn reloadAvailable(_: *const DoorModel, _: *nogui.Session) nogui.action.Availability {
        return .available;
    }

    fn open(self: *DoorModel, _: *const DoorPayload, _: *nogui.Session) !void {
        self.opened += 1;
    }

    fn openAvailable(_: *const DoorModel, _: *nogui.Session) nogui.action.Availability {
        return .available;
    }
};

const DoorCounts = struct {
    reloaded: usize = 0,
    opened: usize = 0,
};

/// Read the door model's record back out of the Session, which is where the
/// model data lives rather than in the handle.
fn doorCounts(session: *nogui.Session, model: nogui.WeakModel(DoorModel)) !DoorCounts {
    const Read = struct {
        fn run(value: *const DoorModel, out: *DoorCounts) void {
            out.* = .{ .reloaded = value.reloaded, .opened = value.opened };
        }
    };
    var out: DoorCounts = .{};
    try session.read(DoorModel, model, &out, Read.run);
    return out;
}

/// The weak probe the router re-checks, so a test can kill a window without
/// releasing the Session model behind it.
const DoorOwner = struct {
    alive: bool = true,

    fn probe(context: *const anyopaque) bool {
        const self: *const DoorOwner = @ptrCast(@alignCast(context));
        return self.alive;
    }

    fn bind(self: *const DoorOwner) weak_owner.WeakOwner {
        return .{ .context = self, .is_alive_fn = DoorOwner.probe };
    }
};

/// The tree the registry resolves the door's actions against.
fn doorTree(gpa: std.mem.Allocator) !nogui.WidgetTree {
    var tree = nogui.WidgetTree.init(gpa);
    errdefer tree.deinit();
    try tree.nodes.append(gpa, .{
        .id = @fromBackingInt(@intCast(1)),
        .widget_id = door_widget,
        .parent = .root,
        .kind = .{ .label = .{ .text = "child" } },
    });
    return tree;
}

/// The WHOLE launch door, in the order the adapter states it: the shell's own
/// splitter decides whether this line is a launch at all, the published models
/// name what the one argument is, and only then may a window be activated.
fn doorLaunch(
    router: *jump_list.Router,
    argv: []const []const u8,
    tasks: []const jump_list.JumpListTask,
    documents: []const jump_list.RecentDocument,
) !void {
    const argument = jump_list.launchArgumentFromArgv(argv) orelse
        return error.NoLaunchArgument;
    const entry = try jump_list.decodeLaunchArgument(argument, tasks, documents);
    _ = try router.activate(entry);
}

test "api-w23 the jump list refuses a task the launch door could never decode" {
    // A task's action name becomes the whole argument list of the shortcut the
    // shell launches, and nothing escapes it there. A name the shell's own
    // splitter would break in two therefore reaches the taskbar menu and comes
    // back as an argument vector this process cannot read as one entry, so the
    // entry would do nothing when it was chosen. That is refused by name here,
    // before the shell is asked for anything.
    const gpa = std.testing.allocator;
    var list = jump_list.JumpList.init(gpa);
    defer list.deinit();
    const documents = [_]jump_list.RecentDocument{.{ .path = "C:\\docs\\one.txt" }};

    // What an action registry hands out: lowercase dotted identifiers with
    // nothing the splitter would read as a separator. The title is a DISPLAY
    // string that never travels on a command line, so its spaces are ordinary.
    const publishable = [_]jump_list.JumpListTask{
        .{ .title = "Add row", .action_name = "w23.add_row" },
        .{
            .title = "Open document",
            .action_name = "w23.open_document",
            .description = "open a document by path",
        },
    };
    list.setJumpListTasks(&publishable);
    list.setRecentDocuments(&documents);
    var model = try list.build();
    defer model.deinit();
    try std.testing.expectEqual(@as(usize, 2), model.tasks.len);

    const unlaunchable = [_][]const u8{
        "w23 add row",
        "w23\tadd",
        "w23\nadd",
        "w23\radd",
        "w23\x0badd",
        "w23\x0cadd",
        "w23\"add",
        "w23\\",
    };
    for (unlaunchable) |action_name| {
        try std.testing.expect(!jump_list.isWholeLaunchArgument(action_name));
        const tasks = [_]jump_list.JumpListTask{.{ .title = "Odd", .action_name = action_name }};
        list.setJumpListTasks(&tasks);
        try std.testing.expectError(error.InvalidEntry, list.build());
    }
    try std.testing.expect(jump_list.isWholeLaunchArgument("w23.add_row"));
    try std.testing.expect(!jump_list.isWholeLaunchArgument(""));

    // A document PATH is quoted by the file-type registration that launches
    // it, which is a separate statement from this one, so a space in a path is
    // left alone and still publishes.
    const spaced_documents = [_]jump_list.RecentDocument{.{ .path = "C:\\my docs\\one.txt" }};
    list.setJumpListTasks(&publishable);
    list.setRecentDocuments(&spaced_documents);
    var spaced = try list.build();
    defer spaced.deinit();
    try std.testing.expectEqual(@as(usize, 1), spaced.documents.len);
}

test "api-w23 an argument with two answers is refused before any window runs" {
    const gpa = std.testing.allocator;
    var session = try nogui.Session.init(gpa);
    defer session.deinit() catch unreachable;
    var registry = try nogui.action.Registry.init(gpa, &session);
    defer registry.deinit();
    try registry.register(door_reload);
    try registry.register(door_open);

    var initial: DoorModel = .{};
    var model = try session.create(DoorModel, &initial);
    defer session.release(DoorModel, &model) catch unreachable;
    _ = try registry.bind(
        door_reload,
        DoorModel,
        DoorModel.reload,
        DoorModel.reloadAvailable,
        .{ .widget = door_widget },
        model.weak(),
    );
    _ = try registry.bind(
        door_open,
        DoorModel,
        DoorModel.open,
        DoorModel.openAvailable,
        .{ .widget = door_widget },
        model.weak(),
    );

    var tree = try doorTree(gpa);
    defer tree.deinit();

    // ONE string published twice: as the action name of one window's task and
    // as the document another window owns. Both windows are alive, so this is
    // an ambiguity and not a death.
    const colliding = "C:\\docs\\one.txt";
    const task_key: jump_list.WindowHandle = .{
        .host = 1,
        .slot = 0,
        .generation = 1,
        .session_window = 21,
    };
    const document_key: jump_list.WindowHandle = .{
        .host = 1,
        .slot = 1,
        .generation = 1,
        .session_window = 22,
    };

    const tasks = [_]jump_list.JumpListTask{.{ .title = "Odd", .action_name = colliding }};
    const documents = [_]jump_list.RecentDocument{.{ .path = colliding }};
    try std.testing.expectError(
        error.AmbiguousLaunchArgument,
        jump_list.decodeLaunchArgument(colliding, &tasks, &documents),
    );

    var task_owner: DoorOwner = .{ .alive = true };
    var document_owner: DoorOwner = .{ .alive = true };
    var bridge = shared_menus.MenuActionBridge.init(&registry);
    var router = jump_list.Router.init(gpa, &bridge);
    defer router.deinit();
    try router.addWindow(.{
        .key = task_key,
        .title = "Odd",
        .action_name = colliding,
        .owner = task_owner.bind(),
        .tree = &tree,
        .focus = door_widget,
    });
    try router.addWindow(.{
        .key = document_key,
        .title = "Docs",
        .action_name = door_reload.name,
        .document_path = colliding,
        .owner = document_owner.bind(),
        .tree = &tree,
        .focus = door_widget,
    });

    // `decodeLaunchArgument` is a convention any caller may skip, because
    // `Activation` is a plain string union. The router is the last thing
    // between an argument and a live dispatch, so it refuses the same name
    // itself rather than running one window's half of it.
    try std.testing.expectError(
        error.AmbiguousActivation,
        router.activate(.{ .task = colliding }),
    );
    try std.testing.expectError(
        error.AmbiguousActivation,
        router.activate(.{ .document = colliding }),
    );
    const after_collision = try doorCounts(&session, model.weak());
    try std.testing.expectEqual(@as(usize, 0), after_collision.reloaded);
    try std.testing.expectEqual(@as(usize, 0), after_collision.opened);
    // Neither claimant was dropped: both windows are still here, so the answer
    // was an ambiguity rather than a death.
    try std.testing.expectEqual(@as(usize, 2), router.routes.items.len);

    // A name only one window claims is still routed, so what was refused is the
    // collision and not the router refusing launches.
    const reached = try router.activate(.{ .task = door_reload.name });
    try std.testing.expect(reached.window.eql(document_key));
    try std.testing.expectEqual(nogui.action.Result.handled, reached.result);
    const after_single = try doorCounts(&session, model.weak());
    try std.testing.expectEqual(@as(usize, 1), after_single.reloaded);

    // The refusal counts LIVE claimants only: the window that published the
    // name as a task is gone, so one answer is left and the argument is a
    // launch that named a window this desktop no longer has. The document
    // window outliving it must not manufacture the second answer.
    task_owner.alive = false;
    try std.testing.expectError(
        error.WindowGone,
        router.activate(.{ .task = colliding }),
    );
    try std.testing.expectEqual(@as(usize, 1), router.routes.items.len);
}

test "api-w23 the launch door decodes before it activates a window" {
    const gpa = std.testing.allocator;
    var session = try nogui.Session.init(gpa);
    defer session.deinit() catch unreachable;
    var registry = try nogui.action.Registry.init(gpa, &session);
    defer registry.deinit();
    try registry.register(door_reload);
    try registry.register(door_open);

    var initial: DoorModel = .{};
    var model = try session.create(DoorModel, &initial);
    defer session.release(DoorModel, &model) catch unreachable;
    _ = try registry.bind(
        door_reload,
        DoorModel,
        DoorModel.reload,
        DoorModel.reloadAvailable,
        .{ .widget = door_widget },
        model.weak(),
    );
    _ = try registry.bind(
        door_open,
        DoorModel,
        DoorModel.open,
        DoorModel.openAvailable,
        .{ .widget = door_widget },
        model.weak(),
    );

    var tree = try doorTree(gpa);
    defer tree.deinit();

    const document_path = "C:\\docs\\one.txt";
    const key: jump_list.WindowHandle = .{
        .host = 1,
        .slot = 0,
        .generation = 1,
        .session_window = 31,
    };

    var owner: DoorOwner = .{ .alive = true };
    var bridge = shared_menus.MenuActionBridge.init(&registry);
    var router = jump_list.Router.init(gpa, &bridge);
    defer router.deinit();
    // ONE window with two entries: the task runs the action that takes no
    // payload and the document runs the action that takes the path.
    try router.addWindow(.{
        .key = key,
        .title = "Docs",
        .action_name = door_reload.name,
        .document_action_name = door_open.name,
        .document_path = document_path,
        .owner = owner.bind(),
        .tree = &tree,
        .focus = door_widget,
    });

    const reload_name = door_reload.name;
    const tasks = [_]jump_list.JumpListTask{.{ .title = "Reload", .action_name = reload_name }};
    const documents = [_]jump_list.RecentDocument{.{ .path = document_path }};
    const exe = "w23-windows-smoke.exe";
    const approval = &.{ exe, reload_name, "--authorize-jump-list-publish" };

    // The two lines the shell writes, and the whole of each: this executable
    // and ONE argument. Each reaches the live model exactly once.
    try doorLaunch(&router, &.{ exe, reload_name }, &tasks, &documents);
    const after_task = try doorCounts(&session, model.weak());
    try std.testing.expectEqual(@as(usize, 1), after_task.reloaded);
    try std.testing.expectEqual(@as(usize, 0), after_task.opened);

    try doorLaunch(&router, &.{ exe, document_path }, &tasks, &documents);
    const after_document = try doorCounts(&session, model.weak());
    try std.testing.expectEqual(@as(usize, 1), after_document.opened);

    // A word a person typed is not a launch: the splitter's own shape is read
    // first, so an approval flag or a second argument never reaches a decode
    // and therefore never reaches a window.
    try std.testing.expectError(
        error.NoLaunchArgument,
        doorLaunch(&router, &.{exe}, &tasks, &documents),
    );
    try std.testing.expectError(
        error.NoLaunchArgument,
        doorLaunch(&router, approval, &tasks, &documents),
    );
    // An argument that names nothing published is refused by the DECODE, which
    // is the step before the router is ever asked.
    try std.testing.expectError(
        error.UnknownActivation,
        doorLaunch(&router, &.{ exe, "--frames" }, &tasks, &documents),
    );
    const after_refusals = try doorCounts(&session, model.weak());
    try std.testing.expectEqual(@as(usize, 1), after_refusals.reloaded);
    try std.testing.expectEqual(@as(usize, 1), after_refusals.opened);

    // A window that has gone is refused before its action runs, and its route
    // is dropped rather than remembered: the next attempt at the same entry
    // names no window at all, which is a different answer by name.
    owner.alive = false;
    try std.testing.expectError(
        error.WindowGone,
        doorLaunch(&router, &.{ exe, reload_name }, &tasks, &documents),
    );
    try std.testing.expectError(
        error.Unrouted,
        doorLaunch(&router, &.{ exe, reload_name }, &tasks, &documents),
    );
    const after_death = try doorCounts(&session, model.weak());
    try std.testing.expectEqual(@as(usize, 1), after_death.reloaded);
    try std.testing.expectEqual(@as(usize, 1), after_death.opened);
    try std.testing.expectEqual(@as(usize, 0), router.routes.items.len);
}

/// The shim that owns every COM object this directory publishes. It is
/// embedded rather than read so the ledger below is a statement about the
/// source that ships, and it is a SOURCE-LEVEL audit: this host compiles the
/// shim for no target, so nothing here is runtime proof that Windows released
/// anything.
const jump_list_shim = @embedFile("native/nogui_jumplist.c");

fn shimOccurrences(needle: []const u8) usize {
    return std.mem.count(u8, jump_list_shim, needle);
}

test "api-w23 every jump-list COM object is released exactly once" {
    // The ledger. Each pointer this shim owns is acquired into a NULL local and
    // released through one macro that forgets what it released, so the count
    // below is the count of exits rather than a reader's care: a new exit that
    // releases through the macro raises its pointer's count, and a release that
    // bypasses the macro raises the one `lpVtbl->Release` the macro holds.
    const ledger = [_]struct { pointer: []const u8, releases: usize }{
        // Three exits inside the task-link builder: a refused setter, a refused
        // property-store interface, and a refused title.
        .{ .pointer = "link", .releases = 5 },
        .{ .pointer = "store", .releases = 1 },
        // One exit each at the end of the publish: the loop's hand-off, and the
        // single place the rest are forgotten.
        .{ .pointer = "list", .releases = 1 },
        .{ .pointer = "tasks_collection", .releases = 1 },
        .{ .pointer = "tasks_array", .releases = 1 },
        .{ .pointer = "removed", .releases = 1 },
    };
    for (ledger) |entry| {
        var name_buffer: [64]u8 = undefined;
        const call = std.fmt.bufPrint(
            &name_buffer,
            "NOGUI_JUMP_RELEASE({s})",
            .{entry.pointer},
        ) catch unreachable;
        try std.testing.expectEqual(
            entry.releases,
            shimOccurrences(call),
        );
    }
    // Every release in the file, including the macro's own definition.
    try std.testing.expectEqual(@as(usize, 11), shimOccurrences("NOGUI_JUMP_RELEASE("));
    // The one and only `Release` in the file is the macro's, so no exit can
    // forget an object or release one twice.
    try std.testing.expectEqual(@as(usize, 1), shimOccurrences("lpVtbl->Release("));
    try std.testing.expectEqual(@as(usize, 1), shimOccurrences("(pointer) = NULL;"));

    // The other three allocations the shim owns: the identity readback the SDK
    // frees with CoTaskMemFree, the module path malloc frees with free, and the
    // apartment it uninitializes only when it initialized one.
    try std.testing.expectEqual(@as(usize, 2), shimOccurrences("CoTaskMemFree("));
    try std.testing.expectEqual(@as(usize, 1), shimOccurrences("CoInitializeEx("));
    try std.testing.expectEqual(@as(usize, 1), shimOccurrences("CoUninitialize()"));

    // Every acquisition the ledger above accounts for: three coclasses, two
    // interface queries and the array `BeginList` hands back.
    try std.testing.expectEqual(@as(usize, 3), shimOccurrences("CoCreateInstance("));
    try std.testing.expectEqual(@as(usize, 2), shimOccurrences("lpVtbl->QueryInterface("));
    try std.testing.expectEqual(@as(usize, 1), shimOccurrences("lpVtbl->BeginList("));

    // The gate the launch door needs runs before COM exists: the entries are
    // checked while the only thing alive is the caller's own view.
    const gate = std.mem.indexOf(
        u8,
        jump_list_shim,
        "nogui_jump_action_is_launchable(tasks[index].action_name)",
    ) orelse return error.ShimGateMissing;
    const com = std.mem.indexOf(u8, jump_list_shim, "CoInitializeEx(") orelse
        return error.ShimComMissing;
    try std.testing.expect(gate < com);

    // The one effect the shell offers no way to take back is written after
    // every step that can fail and before the commit that shows it.
    const tasks_added = std.mem.indexOf(u8, jump_list_shim, "lpVtbl->AddUserTasks(") orelse
        return error.ShimTasksMissing;
    const recorded = std.mem.indexOf(
        u8,
        jump_list_shim,
        "nogui_jump_record_documents(documents, document_count);",
    ) orelse return error.ShimRecordMissing;
    const committed = std.mem.indexOf(u8, jump_list_shim, "lpVtbl->CommitList(") orelse
        return error.ShimCommitMissing;
    try std.testing.expect(tasks_added < recorded);
    try std.testing.expect(recorded < committed);
    try std.testing.expectEqual(@as(usize, 1), shimOccurrences("SHAddToRecentDocs("));
}
