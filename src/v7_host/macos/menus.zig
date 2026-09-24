//! E02: the AppKit menu bar, the Dock menu, and the recent-documents store.
//!
//! The host already owns a menu model (`menus.MenuBar`), a bridge that
//! resolves each item against the focused widget (`menus.MenuActionBridge`)
//! and a recent-documents list (`menus.RecentDocumentsManager`). This module
//! does not add a fourth one. It flattens the *evaluated* model into the flat
//! table the shim builds `NSMenu` objects from, keeps the evaluated rows
//! behind it so a click can be dispatched through the host's own action path,
//! and reports which of the platform's recent documents changed.
//!
//! Two things AppKit owns and this module deliberately does not pretend to:
//! the application menu is the FIRST top-level menu in the table, because macOS
//! draws the app's own menu first and nothing else may claim that slot; and
//! the Open Recent submenu is filled by the platform from the recent-documents
//! store, so its contents are read back rather than mirrored.
//!
//! Who owns which bytes. The shim reads a node table while it builds the
//! `NSMenu` objects and copies every string it keeps — the menu bar becomes
//! `NSString` titles inside `nogui_macos_menu_new`, and the Dock table is
//! duplicated label by label inside `nogui_macos_dock_menu_set` — so a table
//! and its labels only have to outlive the call they are handed to. A click is
//! the opposite: it arrives when a person chooses a row, long after the call
//! that installed the menu and long after the host's own storage — a scratch
//! buffer, next frame's labels — has been rewritten or freed. So the
//! evaluation each table was built from is RETAINED here for as long as that
//! menu is installed, and the row a click dispatches is read from the retained
//! evaluation rather than from the host's storage or from a temporary.
//!
//! The third thing the shim owns decides WHEN those bytes may go. ONE
//! controller holds every menu it built and the callback table those menus
//! report into, and that table's `user` is the adapter record a click reads
//! its row out of. AppKit owns the thread that controller lives on, so an
//! adapter with a menu installed is an adapter whose whole lifetime is the
//! macOS main thread's — `install`, `setDockMenu` and `deinit` alike — and
//! `deinit` says so out loud instead of letting a free the shim refuses
//! leave an installed menu bar pointing at rows this module released.
const std = @import("std");
const native = @import("native.zig");
const host_menus = @import("../menus.zig");

const nogui = @import("nogui");
const Error = native.Error;
const Status = native.Status;
const shim = native.shim;

/// A node kind the shim understands. `recent` is the platform's own Open
/// Recent submenu, which only the Dock menu uses.
const Kind = enum(c_int) {
    menu = 0,
    item = 1,
    separator = 2,
    recent = 3,
};

/// The host's answer to a menu click. It receives the model item, not an
/// index, so the host dispatches through its own action registry with its own
/// focus context instead of this module guessing one.
pub const Dispatch = struct {
    context: ?*anyopaque = null,
    /// A menu item was chosen. The adapter guarantees this runs on the macOS
    /// main thread, which is the host's own thread. Null means this process
    /// answers no clicks.
    item: ?*const fn (?*anyopaque, host_menus.MenuItem) void = null,
    /// A document in the Open Recent submenu was chosen, by position in the
    /// platform's own list. Use `recentPath` for the path. Null means the
    /// platform's recent list is not offered to this process.
    recent: ?*const fn (?*anyopaque, usize) void = null,
};

/// How many high bits of a routing tag name the menu its row belongs to. Two
/// of them are used and two are reserved, so a tag this adapter did not build
/// is recognisable instead of being read as somebody else's row.
const namespace_bits = 30;
/// The largest row index a tag carries: 2^30 - 1. A table that long cannot be
/// built, since one node is forty bytes, but the bound is checked instead of
/// assumed: a narrowed tag would name a row that is not the one clicked.
const row_mask: u32 = (@as(u32, 1) << namespace_bits) - 1;

/// Which installed menu a routing tag belongs to.
///
/// A click carries one integer and two menus number their rows the same way,
/// so the tag says both things: the high bits name the menu and the rest is
/// the row's own index inside that menu's table. Both parts live in the node's
/// `action_index`, which is what the shim puts in the `NSMenuItem` tag it
/// reports back, so a Dock click and a menu-bar click at the same local index
/// arrive as two different integers and neither can name the other's row.
const Namespace = enum(u32) {
    bar = 0,
    dock = 1,

    /// The tag one row of this menu carries.
    fn tag(self: Namespace, index: usize) Error!c_int {
        if (index > row_mask) return error.BadArgument;
        const encoded = (@as(u32, @intFromEnum(self)) << namespace_bits) | @as(u32, @intCast(index));
        return @intCast(encoded);
    }

    /// The row one tag names inside this menu's table, or null when the tag
    /// belongs to another menu or to no menu at all.
    fn row(self: Namespace, reported: c_int) ?usize {
        const encoded: u32 = @bitCast(reported);
        if (encoded >> namespace_bits != @intFromEnum(self)) return null;
        return @intCast(encoded & row_mask);
    }
};

/// One installed menu route: the row behind every node index of one table,
/// and the evaluation those rows borrow their text from.
///
/// The menu bar and the Dock menu are two routes rather than one table because
/// the shim decides that, not this file: one builder builds both, it carries
/// each node's own routing tag in the `NSMenuItem` tag it reports back, and it
/// reports both menus through the one callback table of the one controller
/// that owns them. A shared table would let a Dock install retarget every live
/// menu-bar row, which is what one unnamespaced index would do to a click too.
const Route = struct {
    gpa: std.mem.Allocator,
    /// The row behind each node index, in the table's own order. A menu, a
    /// separator and the Open Recent header are not clickable, so they carry
    /// no row.
    rows: std.ArrayListUnmanaged(?host_menus.MenuItem) = .empty,
    /// The evaluation this route was built from, held rather than released
    /// with the call that built it: every string in a row belongs to this
    /// arena, at every depth, and a click outlives the evaluation the host
    /// passed in by value.
    evaluated: ?host_menus.EvaluatedMenuBar = null,

    fn init(gpa: std.mem.Allocator) Route {
        return .{ .gpa = gpa };
    }

    /// The one place a route is released. The evaluation goes first: the rows
    /// are views of its text, so freeing the arena before the table would
    /// leave a table of rows pointing at nothing.
    fn deinit(self: *Route) void {
        if (self.evaluated) |*bar| bar.deinit();
        self.rows.deinit(self.gpa);
        self.* = undefined;
    }

    /// The row one node index names, or null when this route has none there.
    fn rowAt(self: *const Route, index: usize) ?host_menus.MenuItem {
        if (index >= self.rows.items.len) return null;
        return self.rows.items[index];
    }
};

/// The row a click is dispatched from, in the model's own terms.
///
/// Every string in it belongs to the retained evaluation, and every override
/// is the fact that evaluation resolved for the focused context the menu was
/// built for: the row answers for its own enablement and its own tick mark
/// without asking the registry again, so an inspection of a click cannot
/// disagree with the greyed or ticked row the person chose. A submenu's
/// children are rows of their own, each with its own node index, so this row
/// carries none.
fn modelRow(item: host_menus.EvaluatedItem) host_menus.MenuItem {
    return .{
        .id = item.id,
        .label = item.label,
        .kind = item.kind,
        .action_name = item.action_name,
        .action_payload_json = item.action_payload_json,
        .system_action = item.system_action,
        .shortcut_label = item.shortcut_label,
        .explicit_enabled = item.enabled,
        .explicit_checked = item.checked,
    };
}

/// One table under construction: the C nodes, the labels the shim reads, and
/// the rows those nodes leave behind.
///
/// This is a temporary and a `Route` is what survives it, because the shim has
/// read — and where it keeps them, copied — every byte in here by the time the
/// call it was handed to returns. Only the rows have a later reader.
const Table = struct {
    gpa: std.mem.Allocator,
    namespace: Namespace,
    scratch: native.Scratch,
    nodes: std.ArrayListUnmanaged(shim.nogui_macos_menu_node) = .empty,
    rows: std.ArrayListUnmanaged(?host_menus.MenuItem) = .empty,

    fn init(gpa: std.mem.Allocator, namespace: Namespace) Table {
        return .{ .gpa = gpa, .namespace = namespace, .scratch = native.Scratch.init(gpa) };
    }

    fn deinit(self: *Table) void {
        self.scratch.deinit();
        self.nodes.deinit(self.gpa);
        self.rows.deinit(self.gpa);
        self.* = undefined;
    }

    fn model(self: *const Table) shim.nogui_macos_menu_model {
        return .{ .nodes = self.nodes.items.ptr, .nodes_len = self.nodes.items.len };
    }

    fn menu(self: *Table, entries: host_menus.EvaluatedMenu, parent: c_int) Error!void {
        const index: c_int = @intCast(self.nodes.items.len);
        const label = (try self.scratch.nul(entries.title)) orelse return error.BadArgument;
        try self.nodes.append(self.gpa, .{
            .parent = parent,
            .kind = @intFromEnum(Kind.menu),
            .action_kind = -1,
            .action_index = -1,
            .system_action = -1,
            .enabled = 1,
            .checked = 0,
            .id = 0,
            .label = label,
            .shortcut = null,
        });
        // A menu title carries no row: it has no action to dispatch, and each
        // of its children is a row of its own.
        try self.rows.append(self.gpa, null);
        for (entries.items) |entry| try self.item(entry, index);
    }

    fn item(self: *Table, entry: host_menus.EvaluatedItem, parent: c_int) Error!void {
        const index: usize = self.nodes.items.len;
        switch (entry.kind) {
            .separator => {
                try self.nodes.append(self.gpa, .{
                    .parent = parent,
                    .kind = @intFromEnum(Kind.separator),
                    .action_kind = -1,
                    .action_index = -1,
                    .system_action = -1,
                    .enabled = 0,
                    .checked = 0,
                    .id = @truncate(entry.id),
                    .label = null,
                    .shortcut = null,
                });
                try self.rows.append(self.gpa, null);
                return;
            },
            .submenu => {
                // The evaluated item keeps the submenu's own evaluated items,
                // so a disabled entry inside it is disabled for the same
                // reason as the rest of the bar.
                const sub = entry.submenu orelse return error.BadArgument;
                const label = (try self.scratch.nul(entry.label)) orelse return error.BadArgument;
                const menu_index: c_int = @intCast(index);
                try self.nodes.append(self.gpa, .{
                    .parent = parent,
                    .kind = @intFromEnum(Kind.menu),
                    .action_kind = -1,
                    .action_index = -1,
                    .system_action = -1,
                    .enabled = if (entry.enabled) 1 else 0,
                    .checked = if (entry.checked) 1 else 0,
                    .id = @truncate(entry.id),
                    .label = label,
                    .shortcut = null,
                });
                try self.rows.append(self.gpa, null);
                for (sub) |child| try self.item(child, menu_index);
                return;
            },
            .action, .system_action => {},
        }
        const label = (try self.scratch.nul(entry.label)) orelse return error.BadArgument;
        const shortcut = if (entry.shortcut_label) |text|
            (try self.scratch.nul(text)) orelse return error.BadArgument
        else
            null;
        const system_action: c_int = if (entry.system_action) |action| @intFromEnum(action) else -1;
        try self.nodes.append(self.gpa, .{
            .parent = parent,
            .kind = @intFromEnum(Kind.item),
            // A system action is carried on the node itself; a registry action
            // is carried by the row's routing tag, which is what the host
            // resolves.
            .action_kind = if (entry.system_action != null) 1 else 0,
            // The tag is the row's own routing identity, not its position in
            // this table: two menus number their rows alike, and the namespace
            // bits are what tell a Dock row from a menu-bar row.
            .action_index = try self.namespace.tag(index),
            .system_action = system_action,
            .enabled = if (entry.enabled) 1 else 0,
            .checked = if (entry.checked) 1 else 0,
            // The node's identity field is 32 bits wide and nothing in the shim
            // reads it, so a wider model id is narrowed here rather than
            // refused for a number no platform row will ever see.
            .id = @truncate(entry.id),
            .label = label,
            .shortcut = shortcut,
        });
        try self.rows.append(self.gpa, modelRow(entry));
    }

    fn recent(self: *Table) Error!void {
        try self.nodes.append(self.gpa, .{
            .parent = -1,
            .kind = @intFromEnum(Kind.recent),
            .action_kind = -1,
            .action_index = -1,
            .system_action = -1,
            .enabled = 1,
            .checked = 0,
            .id = 0,
            // A literal rather than a copy: the shim duplicates every string
            // of the table it keeps, this one included.
            .label = "Open Recent",
            .shortcut = null,
        });
        try self.rows.append(self.gpa, null);
    }
};

/// The menus this process installs, and the model behind them.
pub const Adapter = struct {
    gpa: std.mem.Allocator,
    /// The Io the dispatch counters' mutex waits on. A menu click arrives on
    /// the macOS main thread, so the window that owns this adapter has to keep
    /// its Io alive for as long as the shim holds the pointer.
    io: std.Io,
    /// The shim's menu controller. Null before `install` and after `deinit`.
    /// One controller owns BOTH menus, so a new menu bar is also a controller
    /// that carries no Dock menu.
    handle: ?*anyopaque = null,
    closed: bool = false,
    /// The installed menu bar's rows. Empty until `install`.
    bar: Route,
    /// The installed Dock menu's rows. Empty until `setDockMenu`, and empty
    /// again after an `install` that replaced the controller behind them.
    dock: Route,
    /// How many clicks the shim delivered, and how many documents were opened.
    dispatched: u32 = 0,
    recent_chosen: u32 = 0,
    dispatch: Dispatch = .{},
    mutex: std.Io.Mutex = .init,

    /// Allocate one, then initialize it in place: the shim keeps the pointer.
    ///     const adapter = try gpa.create(Adapter);
    ///     errdefer gpa.destroy(adapter);
    ///     adapter.* = Adapter.init(gpa, io);
    pub fn init(gpa: std.mem.Allocator, io: std.Io) Adapter {
        return .{
            .gpa = gpa,
            .io = io,
            .bar = Route.init(gpa),
            .dock = Route.init(gpa),
        };
    }

    /// Release the controller, and with it the rows its clicks name.
    ///
    /// The controller is what holds the callback table, and that table's
    /// `user` is this record, so the free below is the moment a click can no
    /// longer reach the routes released after it. The shim refuses a free off
    /// the macOS main thread by returning without doing anything — the ABI
    /// every `void` `_free` in this shim uses, because a function that returns
    /// nothing has no code to report a refusal with — so the precondition is
    /// checked HERE, before the flag is set, the handle is dropped, or a route
    /// is released. A caller that is anywhere else stops the process with a
    /// message naming why, which is the honest answer: the alternative is an
    /// installed menu bar whose next click dispatches out of released memory.
    ///
    /// This is the one precondition `deinit` carries, and it holds for the
    /// whole adapter rather than for one call: `install` and `setDockMenu` are
    /// refused off the main thread with `error.NotOnMainThread`, so an adapter
    /// that holds a controller was installed on the macOS main thread and is
    /// released there too. While no menu is installed there is nothing native
    /// to detach, and the check does not apply.
    pub fn deinit(self: *Adapter) void {
        // Teardown is a main-thread operation, and it is the last chance to
        // stop the installed menus from naming this record. A teardown from any
        // other thread stops HERE, before one byte is freed: the shim refuses
        // the free off the main thread by returning without doing anything, so
        // the callback table would outlive it with the `user` this function is
        // about to release, and the crash would land a long way from the
        // mistake that made it.
        if (comptime native.available) {
            if (self.handle != null and !native.isMainThread()) @panic(
                "macos menus: Adapter.deinit called off the macOS main thread with a menu installed",
            );
        }
        self.closed = true;
        // The controller goes first, and it zeroes its own callbacks as it
        // detaches its menus: no click can arrive naming rows that are about to
        // go with it. On the macOS main thread that free is a barrier rather
        // than a hope: a click is delivered while AppKit tracks a menu, and
        // tracking is this thread's own work, so no callback is running here
        // while this runs.
        if (self.handle) |handle| {
            self.handle = null;
            if (native.available) shim.nogui_macos_menu_free(handle);
        }
        self.dispatch = .{};
        self.bar.deinit();
        self.dock.deinit();
        self.* = undefined;
    }

    /// Build the menu bar from an already evaluated model and install it as
    /// this process's main menu.
    ///
    /// The evaluation happens in `bridge.evaluate`, against the caller's tree
    /// and focus, so a disabled item is disabled because the host's model says
    /// so and not because AppKit guessed.
    ///
    /// Nothing before the commit at the end of this function changes what is
    /// installed. A refused evaluation, a table the shim will not build, and a
    /// bar `NSApp` will not accept each release what they built and leave the
    /// previous menu — and the rows its clicks name — as they were, because the
    /// previous controller is not released until the replacement is the
    /// process's own menu. A successful install gives up the Dock menu, because
    /// the Dock menu belongs to the controller that was released: a host that
    /// offers both installs the bar first and sets the Dock menu again after
    /// every install.
    pub fn install(
        self: *Adapter,
        bridge: *const host_menus.MenuActionBridge,
        tree: *const nogui.WidgetTree,
        focus: ?nogui.WidgetId,
        bar: host_menus.MenuBar,
    ) Error!void {
        if (!native.available) return error.ShimUnavailable;
        var evaluated = try bridge.evaluate(self.gpa, bar, tree, focus);
        errdefer evaluated.deinit();
        var table = Table.init(self.gpa, .bar);
        defer table.deinit();
        for (evaluated.menus) |menu| {
            try table.menu(menu, -1);
        }
        const model = table.model();
        const callbacks: shim.nogui_macos_menu_callbacks = .{
            .user = @ptrCast(self),
            .on_item = onItem,
            .on_recent = onRecent,
        };
        var out_status: c_int = 0;
        const created = shim.nogui_macos_menu_new(&model, &callbacks, @ptrCast(self), &out_status);
        // Nothing is installed yet: this bar is not `NSApp`'s until the install
        // below, and a bar that could not even be built never became a
        // controller this adapter owns — the shim hands one over exactly once,
        // on the path that succeeds, and releases inside itself on every
        // refusal, because a NULL answer leaves no handle to release it with.
        // The previous controller keeps the process's menu, and this adapter
        // keeps the rows that menu's clicks name.
        if (created == null) return native.fail(Status.of(out_status));
        const installed = Status.of(shim.nogui_macos_menu_install(created));
        if (!installed.isOk()) {
            // The replacement was refused, so the previous one is still the
            // process's menu and still owns the rows its clicks name. Releasing
            // a controller that was never installed cannot take that menu down:
            // the shim clears `NSApp`'s main menu only when the menu it holds is
            // the one being freed.
            shim.nogui_macos_menu_free(created);
            return native.fail(installed);
        }
        // The new bar is the process's menu, so the old controller goes. It
        // owns the old `NSMenu`, which nothing points at now, and it carried
        // the Dock menu, which is why the Dock rows go with it below: that menu
        // and those rows are one thing, and the new controller has neither.
        if (self.handle) |old| {
            self.handle = null;
            shim.nogui_macos_menu_free(old);
        }
        self.dock.deinit();
        self.bar.deinit();
        self.bar = .{
            .gpa = self.gpa,
            .rows = table.rows,
            .evaluated = evaluated,
        };
        // The route owns the rows and the evaluation now, and nothing below
        // this point can fail, so each of them is released exactly once.
        table.rows = .empty;
        self.handle = created;
    }

    /// Replace the Dock menu this process offers.
    ///
    /// A Dock menu is FLAT: the shim builds it from the top level, so its items
    /// sit beside the Open Recent header rather than under a title. The bridge
    /// only evaluates a menu bar, so the dock items ride in one synthetic menu
    /// whose title is never emitted.
    ///
    /// A refused table leaves the Dock menu that was installed, and the rows its
    /// clicks name, exactly as they were. The shim duplicates the whole table,
    /// labels included, before it releases the one it held, so a copy it could
    /// not make is the refusal that leaves the previous table in the controller
    /// and the previous rows correct; and a table it did take is one it refuses
    /// to build again, which is a Dock menu that opens onto nothing rather than
    /// one that opens onto the wrong rows.
    pub fn setDockMenu(
        self: *Adapter,
        bridge: *const host_menus.MenuActionBridge,
        tree: *const nogui.WidgetTree,
        focus: ?nogui.WidgetId,
        dock: host_menus.DockMenu,
    ) Error!void {
        if (!native.available) return error.ShimUnavailable;
        // A Dock menu hangs off the controller that installed the menu bar, so
        // there is nothing to set it on before that exists.
        const handle = self.handle orelse return error.BadArgument;
        var evaluated = try bridge.evaluate(
            self.gpa,
            .{ .menus = &.{.{ .title = "", .items = dock.items }} },
            tree,
            focus,
        );
        errdefer evaluated.deinit();
        var table = Table.init(self.gpa, .dock);
        defer table.deinit();
        for (evaluated.menus) |menu| {
            for (menu.items) |item| try table.item(item, -1);
        }
        // The Open Recent submenu is the platform's, so it is requested by name
        // rather than built from the host's own list.
        try table.recent();
        const model = table.model();
        const installed = Status.of(shim.nogui_macos_dock_menu_set(handle, &model));
        if (!installed.isOk()) return native.fail(installed);
        // The controller holds the copy of the table that was just taken, so
        // these are the rows a Dock click names from here on.
        self.dock.deinit();
        self.dock = .{
            .gpa = self.gpa,
            .rows = table.rows,
            .evaluated = evaluated,
        };
        table.rows = .empty;
    }

    /// The host's answer to menu clicks. Installed once; a host that has not
    /// set one gets no clicks at all rather than unhandled ones.
    pub fn setDispatch(self: *Adapter, dispatch: Dispatch) void {
        self.dispatch = dispatch;
    }

    /// Clicks delivered, and documents opened through the Dock menu.
    pub fn counters(self: *const Adapter) struct { dispatched: u32, recent: u32 } {
        return .{ .dispatched = self.dispatched, .recent = self.recent_chosen };
    }

    /// The row behind one node index of the installed menu bar, for a host that
    /// wants to inspect a row before dispatching it.
    ///
    /// The row borrows the retained evaluation the bar was built from, so it
    /// answers until the next `install` and until `deinit`. It never answers
    /// for the Dock menu: those indices name a different table.
    pub fn itemAt(self: *const Adapter, index: usize) ?host_menus.MenuItem {
        return self.bar.rowAt(index);
    }

    fn fromUser(user: ?*anyopaque) ?*Adapter {
        const ptr = user orelse return null;
        const self: *Adapter = @ptrCast(@alignCast(ptr));
        if (self.closed) return null;
        return self;
    }

    /// The row one reported tag names.
    ///
    /// A tag says which menu the click came from and which row of it, so there
    /// is nothing here to guess: the tag of one menu answers from that menu's
    /// table alone, and a tag that names no installed row answers nothing.
    fn resolve(self: *const Adapter, tag: c_int) ?host_menus.MenuItem {
        if (Namespace.bar.row(tag)) |index| return self.bar.rowAt(index);
        if (Namespace.dock.row(tag)) |index| return self.dock.rowAt(index);
        return null;
    }

    /// The second argument is the clicked row's own routing tag; the model
    /// item supplies the system action, so the third argument is ABI-only.
    fn onItem(user: ?*anyopaque, tag: c_int, _: c_int) callconv(.c) void {
        const self = Adapter.fromUser(user) orelse return;
        if (tag < 0) return;
        const item = self.resolve(tag) orelse return;
        const dispatch = self.dispatch;
        const deliver = dispatch.item orelse return;
        self.mutex.lockUncancelable(self.io);
        self.dispatched +%= 1;
        self.mutex.unlock(self.io);
        deliver(dispatch.context, item);
    }

    fn onRecent(user: ?*anyopaque, index: c_int) callconv(.c) void {
        const self = Adapter.fromUser(user) orelse return;
        if (index < 0) return;
        const dispatch = self.dispatch;
        const deliver = dispatch.recent orelse return;
        self.mutex.lockUncancelable(self.io);
        self.recent_chosen +%= 1;
        self.mutex.unlock(self.io);
        deliver(dispatch.context, @intCast(index));
    }
};

/// Note a document in the platform's recent-documents store, which is what
/// makes it appear in Open Recent and in the Dock menu.
pub fn noteRecent(path: []const u8) Error!void {
    if (!native.available) return error.ShimUnavailable;
    var scratch = native.Scratch.init(std.heap.page_allocator);
    defer scratch.deinit();
    const owned = (try scratch.nul(path)) orelse return error.BadArgument;
    try native.check(Status.of(shim.nogui_macos_recent_add(owned)));
}

pub fn clearRecent() Error!void {
    if (!native.available) return error.ShimUnavailable;
    try native.check(Status.of(shim.nogui_macos_recent_clear()));
}

/// The platform's recent document paths, in its own order and separated by
/// newlines. Owned by `gpa`; release it with `freeRecentList`.
pub fn recentList(gpa: std.mem.Allocator) Error![]u8 {
    return native.readString(gpa, .recent_list, 0, null);
}

pub fn freeRecentList(gpa: std.mem.Allocator, list: []u8) void {
    gpa.free(list);
}

/// One path from the platform's recent-documents store.
pub fn recentPath(gpa: std.mem.Allocator, index: usize) Error![]u8 {
    const list = try recentList(gpa);
    defer gpa.free(list);
    var at: usize = 0;
    var seen: usize = 0;
    while (at <= list.len) {
        const end = std.mem.indexOfScalar(u8, list[at..], '\n') orelse list.len - at;
        if (seen == index) return gpa.dupe(u8, list[at .. at + end]);
        seen += 1;
        if (at + end >= list.len) break;
        at += end + 1;
    }
    return error.BadArgument;
}

/// Copy the platform's recent documents into the host's own list, replacing
/// what was there. The host's list is the one its model reads; the platform's
/// store is the one a person sees, and this keeps the two from drifting.
pub fn syncRecent(gpa: std.mem.Allocator, manager: *host_menus.RecentDocumentsManager) Error!void {
    const list = try recentList(gpa);
    defer gpa.free(list);
    manager.clear();
    var at: usize = 0;
    while (at < list.len) {
        const end = std.mem.indexOfScalarPos(u8, list, at, '\n') orelse list.len;
        if (end > at) try manager.addDocument(list[at..end]);
        if (end >= list.len) break;
        at = end + 1;
    }
}

/// One evaluation, assembled the way `MenuActionBridge.evaluate` assembles
/// one: every row and every byte of text in an arena that is handed over with
/// the bar, and owned by whoever keeps the bar.
fn evaluatedBar(gpa: std.mem.Allocator, name: []const u8) !host_menus.EvaluatedMenuBar {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const alloc = arena.allocator();
    const items = try alloc.alloc(host_menus.EvaluatedItem, 1);
    items[0] = .{
        .id = 1,
        .label = "Open",
        .enabled = true,
        .checked = false,
        .kind = .action,
        .action_name = try alloc.dupe(u8, name),
    };
    const menus = try alloc.alloc(host_menus.EvaluatedMenu, 1);
    menus[0] = .{ .title = "File", .items = items };
    return .{ .menus = menus, .arena = arena };
}

test "api-w23 a retained macos menu row outlives the call that built it" {
    const gpa = std.testing.allocator;
    var adapter = Adapter.init(gpa, undefined);
    defer adapter.deinit();
    const evaluated = try evaluatedBar(gpa, "file.open");
    var table = Table.init(gpa, .bar);
    defer table.deinit();
    for (evaluated.menus) |menu| try table.menu(menu, -1);
    // The node table is a temporary the shim reads and copies before the call
    // that took it returns; only the rows have a reader that arrives later.
    try std.testing.expect(adapter.itemAt(1) == null);
    adapter.bar = .{ .gpa = gpa, .rows = table.rows, .evaluated = evaluated };
    table.rows = .empty;
    const row = adapter.itemAt(1) orelse return error.RowMissing;
    // The row's text is the retained evaluation's, at every depth, and the
    // route is what releases it. A caller that kept the evaluation instead
    // would leak it here, and a route that released it twice would be caught
    // by the testing allocator either way.
    try std.testing.expectEqualStrings("Open", row.label);
    try std.testing.expectEqualStrings("file.open", row.action_name.?);
}

/// One evaluation assembled from the CALLER's own bytes, the way
/// `MenuActionBridge.evaluate` assembles one: every string is copied into the
/// evaluation's own arena, so the buffer it was built from is the host's to
/// rewrite or release the moment this returns.
fn evaluatedRow(
    gpa: std.mem.Allocator,
    id: u64,
    label: []const u8,
    action: []const u8,
) !host_menus.EvaluatedMenuBar {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const alloc = arena.allocator();
    const items = try alloc.alloc(host_menus.EvaluatedItem, 1);
    items[0] = .{
        .id = id,
        .label = try alloc.dupe(u8, label),
        .enabled = true,
        .checked = false,
        .kind = .action,
        .action_name = try alloc.dupe(u8, action),
    };
    const menus = try alloc.alloc(host_menus.EvaluatedMenu, 1);
    menus[0] = .{ .title = "File", .items = items };
    return .{ .menus = menus, .arena = arena };
}

/// The model behind the menu bar's rows. It is an ordinary record with a
/// counter of its own, and it cannot name the Dock's model at all: that is
/// what makes a row that crossed between the two menus count somewhere it must
/// not, instead of being absorbed.
const BarModel = struct {
    clicks: u32 = 0,
    last: host_menus.MenuItem = .{},

    fn record(self: *BarModel, item: host_menus.MenuItem) void {
        self.clicks += 1;
        self.last = item;
    }
};

/// The same for the Dock menu's rows.
const DockModel = struct {
    clicks: u32 = 0,
    last: host_menus.MenuItem = .{},

    fn record(self: *DockModel, item: host_menus.MenuItem) void {
        self.clicks += 1;
        self.last = item;
    }
};

/// What a host hands the adapter: one context, and the callback that resolves a
/// clicked row against the host's OWN models.
///
/// The row is matched on the identity it travels with and never on the menu it
/// arrived from, because the menu it arrived from is the thing under test.
const Host = struct {
    bar: BarModel = .{},
    dock: DockModel = .{},
    /// Clicks carrying an identity this host owns no model for.
    unnamed: u32 = 0,

    const bar_row: u64 = 101;
    const dock_row: u64 = 202;

    fn onItem(context: ?*anyopaque, item: host_menus.MenuItem) void {
        const self: *Host = @ptrCast(@alignCast(context orelse return));
        switch (item.id) {
            bar_row => self.bar.record(item),
            dock_row => self.dock.record(item),
            else => {
                self.unnamed += 1;
            },
        }
    }
};

test "api-w23 one local row index dispatches into each macos menu's own model" {
    // A click takes the adapter's dispatch mutex, so this is the one test here
    // that needs a real Io rather than a stub.
    var io_impl = std.Io.Threaded.init(std.testing.allocator, .{});
    defer io_impl.deinit();
    const gpa = std.testing.allocator;
    var adapter = Adapter.init(gpa, io_impl.io());
    defer adapter.deinit();

    // The host's own bytes, which a menu bar is assembled from and which the
    // next frame is free to rewrite.
    var bar_source = "Bar Open".*;
    var dock_source = "Dock Open".*;

    // Both tables put their action row at local index ONE: the bar's title is
    // node 0 and the Dock's separator is node 0. Two menus and one index is
    // the collision the routing tag exists to keep apart.
    const bar_evaluated = try evaluatedRow(gpa, Host.bar_row, bar_source[0..], "bar.action");
    {
        var table = Table.init(gpa, .bar);
        defer table.deinit();
        for (bar_evaluated.menus) |menu| try table.menu(menu, -1);
        adapter.bar = .{ .gpa = gpa, .rows = table.rows, .evaluated = bar_evaluated };
        table.rows = .empty;
    }
    const separator: host_menus.EvaluatedItem = .{
        .id = 0,
        .label = "",
        .enabled = false,
        .checked = false,
        .kind = .separator,
    };
    const dock_evaluated = try evaluatedRow(gpa, Host.dock_row, dock_source[0..], "dock.action");
    {
        var table = Table.init(gpa, .dock);
        defer table.deinit();
        try table.item(separator, -1);
        for (dock_evaluated.menus) |menu| {
            for (menu.items) |item| try table.item(item, -1);
        }
        try table.recent();
        adapter.dock = .{ .gpa = gpa, .rows = table.rows, .evaluated = dock_evaluated };
        table.rows = .empty;
    }
    // Both node tables are gone with the scratch holding the labels the shim
    // would have copied, and the host's own bytes are overwritten: every byte
    // a click below still reads is the retained evaluation's, which is the only
    // reader left of them.
    @memset(bar_source[0..], 'X');
    @memset(dock_source[0..], 'X');

    var host: Host = .{};
    adapter.setDispatch(.{ .context = @ptrCast(&host), .item = Host.onItem });

    // What the shim reports for a chosen row is the tag its node carried, and
    // nothing else: one integer that has to name the menu as well as the row.
    Adapter.onItem(@ptrCast(&adapter), try Namespace.bar.tag(1), -1);
    Adapter.onItem(@ptrCast(&adapter), try Namespace.dock.tag(1), -1);

    // Each click reached its own model, exactly once, carrying its own row. A
    // tag that did not carry the menu would have delivered both to one row,
    // which is one model twice and the other not at all.
    try std.testing.expectEqual(@as(u32, 1), host.bar.clicks);
    try std.testing.expectEqual(@as(u32, 1), host.dock.clicks);
    try std.testing.expectEqual(@as(u32, 0), host.unnamed);
    try std.testing.expectEqualStrings("Bar Open", host.bar.last.label);
    try std.testing.expectEqualStrings("bar.action", host.bar.last.action_name.?);
    try std.testing.expectEqualStrings("Dock Open", host.dock.last.label);
    try std.testing.expectEqualStrings("dock.action", host.dock.last.action_name.?);
    const dispatched = adapter.counters();
    try std.testing.expectEqual(@as(u32, 2), dispatched.dispatched);
    try std.testing.expectEqual(@as(u32, 0), dispatched.recent);

    // A menu title, a separator, the platform's own Open Recent header and an
    // index neither table reached are not rows, so choosing one is a no-op
    // rather than somebody else's row.
    Adapter.onItem(@ptrCast(&adapter), try Namespace.bar.tag(0), -1);
    Adapter.onItem(@ptrCast(&adapter), try Namespace.dock.tag(0), -1);
    Adapter.onItem(@ptrCast(&adapter), try Namespace.dock.tag(2), -1);
    Adapter.onItem(@ptrCast(&adapter), try Namespace.bar.tag(9), -1);
    // The two live namespaces are the only ones whose tags fit a non-negative
    // int32, so a reserved namespace never reaches the resolver at all and
    // `onItem` refuses the sign before it looks at the high bits. The resolver
    // answers for it anyway, because that is the property a wider int would
    // have to keep.
    const reserved: c_int = @bitCast(@as(u32, 2) << namespace_bits);
    Adapter.onItem(@ptrCast(&adapter), reserved, -1);
    Adapter.onItem(@ptrCast(&adapter), -1, -1);
    try std.testing.expect(adapter.resolve(reserved) == null);
    try std.testing.expect(adapter.resolve(-1) == null);
    // Nothing was dispatched and no model was credited for a row that is not
    // there: a crossed delivery would have shown up as a second click above.
    const quiet = adapter.counters();
    try std.testing.expectEqual(@as(u32, 2), quiet.dispatched);
    try std.testing.expectEqual(@as(u32, 0), quiet.recent);
    try std.testing.expectEqual(@as(u32, 1), host.bar.clicks);
    try std.testing.expectEqual(@as(u32, 1), host.dock.clicks);
    try std.testing.expectEqual(@as(u32, 0), host.unnamed);
}

test "api-w23 a macos routing tag refuses a row it cannot name" {
    // The bound is checked, not assumed: a tag narrowed to fit would name a
    // row the person did not click, which is the one failure a routing tag
    // must not have.
    try std.testing.expectError(error.BadArgument, Namespace.bar.tag(@as(usize, row_mask) + 1));
    try std.testing.expectError(error.BadArgument, Namespace.dock.tag(@as(usize, row_mask) + 1));
    const last: usize = @intCast(row_mask);
    try std.testing.expectEqual(last, Namespace.bar.row(try Namespace.bar.tag(last)).?);
    try std.testing.expectEqual(last, Namespace.dock.row(try Namespace.dock.tag(last)).?);
    // A tag of one menu is never a row of the other.
    try std.testing.expect(Namespace.dock.row(try Namespace.bar.tag(7)) == null);
    try std.testing.expect(Namespace.bar.row(try Namespace.dock.tag(7)) == null);
}
