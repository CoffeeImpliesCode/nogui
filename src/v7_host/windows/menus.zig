//! Windows native menus: a real `HMENU` built from the shared `MenuBar` model
//! and driven through the shared `MenuActionBridge`.
//!
//! Windows has a genuine global menu bar -- it is a window menu set with
//! `SetMenu` -- so unlike the X11 and Wayland drivers, nothing here is a
//! substitute. The adapter owns three jobs and no more:
//!
//!   1. Turn a `MenuBar` plus one `EvaluatedMenuBar` into an `HMENU` tree.
//!      Enablement and check state come from the *evaluated* bar, which the
//!      `MenuActionBridge` produces against the live focused context, so a
//!      grayed row is grayed because the action registry said the action is not
//!      available -- not because this file guessed.
//!   2. Map a `WM_COMMAND` identifier back to the `MenuItem` that produced it
//!      and hand that item to `MenuActionBridge.dispatchItem`. The action then
//!      runs through the W10 action registry like every other route into it, so
//!      a native menu click and an in-app click reach the same handler.
//!   3. Re-evaluate on `WM_INITMENUPOPUP`, the message Windows sends
//!      immediately before a popup is shown. That is the only moment a native
//!      menu's enablement can be correct, and a menu built once and never
//!      refreshed is a menu that lies about what is clickable.
//!
//!   4. Own the window's messages. `Subclass` puts this directory's own
//!      procedure on the window, so a real `WM_COMMAND` from a real menu
//!      click arrives here, is resolved against the route table below and
//!      dispatched through the same bridge, and every other message is
//!      forwarded to the procedure that was there before. A host that never
//!      installs it has a menu it can look at and not operate.
//!
//!   5. ONE ATTACHMENT PER WINDOW. A window procedure is one address, so two
//!      records for one `HWND` cannot both answer a message: the newer one
//!      would take every message while the older still believed it owned the
//!      window, and the older detach would put the procedure that was there
//!      before adoption back over the newer one. `Subclass.attach` refuses a
//!      window that already carries an attachment of this directory's, and it
//!      refuses before any native call.
//!
//!   6. THE MENU OWNS THE ATTACHMENTS THAT ROUTE FOR IT. A window procedure
//!      reaches a menu only through the record it finds for that message's
//!      window, so `WindowMenu.deinit` retires those records before it
//!      releases the `HMENU`, the route table or the evaluation arena. A
//!      caller whose own `defer`s release the menu before the attachment gets
//!      the same result, and a `detach` after that release finds nothing left
//!      to do.
//!
//! Command identifiers. `HMENU` identifies a row by an integer, `MenuItem.id`
//! is a `u64` that defaults to zero, and `WM_COMMAND` carries the identifier in
//! a `WORD`. So the adapter numbers its own rows from one and keeps a table
//! from that number back to the model row.
//! A caller therefore does not manage command ids, and two rows with the same
//! `MenuItem.id` still resolve correctly, because the table is positional
//! rather than keyed on the model's id. Separators and submenu headers consume
//! no identifier, so the last real row stays routable.
//!
//! Table addressing. A row's slot in `routes` IS the identifier the adapter
//! gave it: the row numbered `n` is stored at `routes[n]`, and `routes[0]` is
//! the unused zero slot. That is why a lookup is an index and not an offset --
//! subtracting the first identifier would answer every command with the row
//! before it, and the first command with the unused slot, which is a `MenuItem`
//! with no action name and so dispatches to nothing.
//!
//! Route ownership. A route is the model's row as the menu KEEPS it, so every
//! string it carries comes from the evaluation this menu retains rather than
//! from the `MenuBar` the caller passed in. That bar is scratch storage in
//! every real host -- a frame arena, a builder's temporary -- and it is
//! released as soon as `build` returns, while the menu, its route table and
//! the clicks it routes live as long as the window does. A route that borrowed
//! the model's strings would dispatch an action name out of freed memory, and
//! the failure is silent: the row still draws, still greys and still checks,
//! and only the click is wrong. The values the evaluation does not carry --
//! `id` and the two explicit overrides -- are copied from the model, because a
//! scalar needs no owner.
//!
//! A refresh moves EVERY route onto the incoming evaluation before the
//! previous one is released, so no route ever names storage that has already
//! been freed. A bar whose command rows are not the rows the table routes is
//! refused whole: the previous evaluation stays installed and still owns every
//! route string, and the bar that was handed over is released rather than
//! leaked.
//!
//! Row order. Rows are appended at the current item count rather than inserted
//! at position zero, so the native menu reads in the same order the model does.
//! Inserting at zero would reverse every submenu, which is a menu that works
//! and is wrong.
//!
//! Nothing here touches focus, widgets or the task queue. The bridge owns all
//! of that, and this file only turns a native message into a call on it.
const std = @import("std");
const sdl3 = @import("sdl3");
const win = @import("win32.zig");
const menus = @import("../menus.zig");
const window_interop = @import("window_interop.zig");
const nogui = @import("nogui");

const MenuBar = menus.MenuBar;
const MenuItem = menus.MenuItem;
const EvaluatedMenuBar = menus.EvaluatedMenuBar;
const EvaluatedMenu = menus.EvaluatedMenu;
const EvaluatedItem = menus.EvaluatedItem;
const MenuActionBridge = menus.MenuActionBridge;

/// The first identifier the adapter hands out. Zero is reserved, because it is
/// what Windows sends for "no command".
const first_command: win.Dword = 1;

pub const Error = error{
    /// The model described a submenu with no rows, or rows whose model and
    /// evaluated forms disagree. A native menu cannot express that, and a menu
    /// that silently drops a row is a menu the user cannot use.
    MalformedMenu,
    /// The platform refused the menu. `CreatePopupMenu` returning null means the
    /// call failed, not that the menu was empty.
    NativeMenuRefused,
    /// A row label is not valid UTF-8, so it cannot be widened for the menu. A
    /// mangled label is a row the user cannot recognize, and dropping it would
    /// drop a command with it.
    InvalidUtf8,
    /// The window published no native window handle, so there is no window
    /// procedure to install this directory's messages into.
    NoNativeWindow,
    /// The window manager refused the procedure swap. `SetWindowLongPtrW`
    /// reports "there was no previous procedure" and "the call failed" the
    /// same way -- a zero return -- so the two are told apart by the last
    /// error, the same way `window_interop` tells a legal style from a
    /// refused one.
    SubclassRefused,
    /// This window already carries an attachment from this directory. A window
    /// holds one window procedure, so a second record for it could only shadow
    /// the first: the newer one would answer every message, and the older
    /// detach would put the pre-adoption procedure back over the newer one. The
    /// window is left exactly as it was, because the refusal comes before any
    /// native call and before the caller's record is filled.
    SubclassAlreadyAttached,
} || std.mem.Allocator.Error;

/// One command row, addressed by the identifier Windows sends back.
pub const Route = struct {
    /// The evaluated row this command dispatches from.
    ///
    /// It is the EVALUATION's row and not the model's, because that is the copy
    /// that outlives the caller: every string it carries points into the arena
    /// the menu owns and `deinit` releases, while the model's own text is the
    /// scratch storage a host rewrites or frees as soon as `build` returns. A
    /// route holding a model row would keep a dangling action name and a
    /// dangling payload for as long as the window is open.
    ///
    /// The row is held by value and its strings are owned by the arena, so a
    /// refresh repoints every route onto the incoming evaluation BEFORE the
    /// previous arena is released.
    item: EvaluatedItem,
    /// The model's own explicit overrides. They are scalars, so they have no
    /// lifetime to own and are copied straight out of the model row.
    ///
    /// They are kept because a consumer that re-asks the bridge about a route
    /// must get the answer the model declared, not the registry's: a row the
    /// model pinned as unavailable stays unavailable here even in a context
    /// where the action is bound.
    explicit_enabled: ?bool,
    explicit_checked: ?bool,
    /// Where the row sits, so a refresh writes new state into exactly this
    /// `HMENU` slot without walking the model again.
    parent: win.Hmenu,
    position: win.Dword,
    /// The model row this route dispatches as.
    ///
    /// Every string comes from the evaluated row the route holds, and only the
    /// scalars come from the model the build read. That split is what makes the
    /// row safe to keep for the window's lifetime: the strings are owned by the
    /// evaluation the menu retains, and the scalars have no lifetime to own.
    ///
    /// It is named for the SHAPE it rebuilds rather than for what a caller does
    /// with it, because nothing here dispatches: the bridge does, under the
    /// live context, and this row is only the argument it is given.
    ///
    /// `submenu` is null because a route only ever holds a command row, and a
    /// command row's children are their own routes. Carrying the model's nested
    /// slice here would borrow scratch storage and duplicate a walk.
    pub fn modelRow(self: Route) MenuItem {
        return .{
            .id = self.item.id,
            .label = self.item.label,
            .kind = self.item.kind,
            .action_name = self.item.action_name,
            .action_payload_json = self.item.action_payload_json,
            .system_action = self.item.system_action,
            .shortcut_label = self.item.shortcut_label,
            .explicit_enabled = self.explicit_enabled,
            .explicit_checked = self.explicit_checked,
            .submenu = null,
        };
    }
};

/// True when this build can attach a real window menu bar.
///
/// This is deliberately not the shared `menus.hasNativeGlobalMenu`, which
/// answers for the Linux drivers SDL3 offers and which have no global menu at
/// all. On Windows the answer is yes, and the adapter below is what makes it
/// true rather than merely claimed.
pub fn hasNativeGlobalMenu() bool {
    return comptime win.is_windows;
}

/// The `HWND` SDL published for a window, or null when the backend has none.
///
/// This delegates to `window_interop.getHwnd`, which is the one place in the
/// Windows adapters that reads a native window handle, and it reads it from an
/// SDL window property. No graphics handle is read anywhere in this directory:
/// the Vulkan surface belongs to noapi, and an adapter that wanted one would
/// have to ask noapi for it.
pub fn hwndOf(window: sdl3.video.Window) ?win.Hwnd {
    return window_interop.getHwnd(window);
}

/// One built native menu. The `HMENU` belongs to whoever attached it; a menu
/// that was built and never attached is released by `deinit`.
pub const NativeMenu = struct {
    gpa: std.mem.Allocator,
    native: win.Hmenu,
    /// Command identifier to evaluated row. Index zero is unused, because
    /// identifier zero is what Windows sends for "no command". Every row's
    /// strings are owned by `evaluated`, so the table is valid exactly as long
    /// as that arena is.
    routes: []Route,
    /// The evaluation every route's strings belong to. It is retained for two
    /// reasons at once: it owns the route table's text, and it is the shape a
    /// refresh is checked against. It is released by `deinit`, after the
    /// routes that point into it.
    evaluated: ?EvaluatedMenuBar,

    pub fn deinit(self: *NativeMenu) void {
        if (comptime win.is_windows) _ = win.DestroyMenu(self.native);
        self.gpa.free(self.routes);
        if (self.evaluated) |*bar| bar.deinit();
        self.* = undefined;
    }

    /// The row a `WM_COMMAND` identifier names, or null when the identifier is
    /// not one of this menu's rows. The row's strings belong to `evaluated`, so
    /// the returned value is valid until `deinit` and no longer.
    pub fn routeFor(self: *const NativeMenu, command: win.Dword) ?Route {
        const index = commandIndex(self.routes.len, command) orelse return null;
        return self.routes[index];
    }
};

/// The table slot a `WM_COMMAND` identifier names, or null when it names none.
///
/// `build` stores the row it numbered `first_command + n` at `routes[n + 1]`,
/// so slot zero is the unused placeholder and every real row's slot is its own
/// identifier. An identifier below the first one, or past the last row, names
/// nothing: zero is what Windows sends for "no command", and anything the
/// adapter never assigned is not this menu's to route.
fn commandIndex(route_count: usize, command: win.Dword) ?usize {
    if (command < first_command) return null;
    const index: usize = command;
    if (index >= route_count) return null;
    return index;
}

/// Build a native menu from an evaluated menu bar.
///
/// The evaluation is the caller's, not this file's, because only the caller
/// knows the `WidgetTree` and the focused context. Passing an
/// `EvaluatedMenuBar` is what makes the native rows agree with the shared
/// action registry instead of with a second opinion computed here.
///
/// The bar is an arena the caller handed over by value, so this function owns
/// it: a refusal releases it rather than dropping it, and a built menu keeps it
/// for two reasons at once -- it is the shape a refresh is checked against, and
/// it owns every string the route table hands out. There is no third place to
/// look for it.
///
/// Nothing here keeps the caller's `menu_bar`. It is read while the call lasts
/// and dropped at the return, because the routes name their actions out of the
/// evaluation rather than out of the model.
pub fn build(gpa: std.mem.Allocator, menu_bar: MenuBar, incoming: EvaluatedMenuBar) Error!NativeMenu {
    var evaluated = incoming;
    errdefer evaluated.deinit();
    if (comptime !win.is_windows) {
        // Off Windows there is no `HMENU` to build. The model and the evaluation
        // still exist and are still usable; only the native menu is absent, and
        // it is absent by name.
        return error.NativeMenuRefused;
    }
    if (evaluated.menus.len != menu_bar.menus.len) return error.MalformedMenu;

    const native = win.CreatePopupMenu() orelse return error.NativeMenuRefused;
    errdefer _ = win.DestroyMenu(native);

    // Slot zero is reserved; every command row is initialized by appendRows.
    var capacity: usize = 1;
    for (menu_bar.menus) |menu| capacity += countItems(menu.items);
    const routes = try gpa.alloc(Route, capacity);
    errdefer gpa.free(routes);
    routes[0] = .{
        .item = .{
            .id = 0,
            .label = "",
            .enabled = false,
            .checked = false,
            .kind = .action,
        },
        .explicit_enabled = null,
        .explicit_checked = null,
        .parent = native,
        .position = 0,
    };
    var used: usize = 0;

    for (menu_bar.menus, evaluated.menus) |model, live| {
        try appendRows(gpa, native, model.items, live.items, routes, &used);
    }

    return .{
        .gpa = gpa,
        .native = native,
        .routes = routes[0 .. used + 1],
        .evaluated = evaluated,
    };
}

/// The number of command rows a bar can produce. Separators and submenu headers
/// are not commands and must not consume an identifier.
fn countItems(items: []const MenuItem) usize {
    var total: usize = 0;
    for (items) |item| {
        switch (item.kind) {
            .separator => {},
            .submenu => {
                const sub = item.submenu orelse continue;
                total += countItems(sub);
            },
            else => total += 1,
        }
    }
    return total;
}

/// The slot a new row goes into. Appending at the current count is what keeps
/// the native menu in the model's order.
fn nextPosition(parent: win.Hmenu) win.Dword {
    const count = win.GetMenuItemCount(parent);
    return if (count < 0) 0 else @intCast(count);
}

fn appendRows(
    gpa: std.mem.Allocator,
    parent: win.Hmenu,
    items: []const MenuItem,
    live: []const EvaluatedItem,
    routes: []Route,
    used: *usize,
) Error!void {
    if (items.len != live.len) return error.MalformedMenu;
    for (items, live) |item, state| {
        const position = nextPosition(parent);
        switch (item.kind) {
            .separator => {
                var info: win.MenuItemInfoW = std.mem.zeroes(win.MenuItemInfoW);
                info.cbSize = @sizeOf(win.MenuItemInfoW);
                info.fMask = win.mii_separator_id;
                info.fType = win.mft_separator;
                if (!win.InsertMenuItemW(parent, position, 0, &info)) {
                    return error.NativeMenuRefused;
                }
            },
            .submenu => {
                // A submenu with no rows is not something Windows can draw, so
                // it is refused rather than attached as a popup that opens onto
                // nothing.
                const children = item.submenu orelse return error.MalformedMenu;
                const sub_native = win.CreatePopupMenu() orelse return error.NativeMenuRefused;
                errdefer _ = win.DestroyMenu(sub_native);
                try appendRows(
                    gpa,
                    sub_native,
                    children,
                    state.submenu orelse return error.MalformedMenu,
                    routes,
                    used,
                );

                const label = try win.wide(gpa, state.label);
                defer gpa.free(label);
                var info: win.MenuItemInfoW = std.mem.zeroes(win.MenuItemInfoW);
                info.cbSize = @sizeOf(win.MenuItemInfoW);
                info.fMask = win.mii_submenu_id;
                info.fType = win.mft_string;
                info.fState = stateFlags(state);
                info.hSubMenu = sub_native;
                info.dwTypeData = @constCast(label.ptr);
                if (!win.InsertMenuItemW(parent, position, 0, &info)) {
                    return error.NativeMenuRefused;
                }
            },
            .action, .system_action => {
                // The label is widened from the EVALUATED row, because that is
                // the copy whose bytes this menu owns. A row drawn from the
                // caller's scratch text shows whatever the caller wrote there
                // next, under a dispatch that no longer matches the label.
                const label = try win.wide(gpa, state.label);
                defer gpa.free(label);
                // The route is stored by the seam below, which is the one
                // decision about ownership this adapter makes.
                const command: win.Dword = storeRoute(routes, used, item, state, parent, position);

                var info: win.MenuItemInfoW = std.mem.zeroes(win.MenuItemInfoW);
                info.cbSize = @sizeOf(win.MenuItemInfoW);
                info.fMask = win.mii_string_id;
                info.fType = win.mft_string;
                info.fState = stateFlags(state);
                info.wID = command;
                info.dwTypeData = @constCast(label.ptr);
                if (!win.InsertMenuItemW(parent, position, 0, &info)) {
                    return error.NativeMenuRefused;
                }
            },
        }
    }
}

/// Store one command row and hand back the identifier it was given.
///
/// This is the ownership seam of the whole adapter, and it is where the
/// evaluation's strings replace the model's. The route keeps the EVALUATED row
/// and the model's two overrides, because the model's slices are the caller's
/// storage and this table outlives the call while those two are scalars that
/// do not. Storing the model row itself is the bug this exists to prevent: the
/// table would then keep an action name and a payload pointing into a scratch
/// buffer the caller freed the moment `build` returned, and the failure is
/// silent because the row still draws, still greys and still checks.
///
/// The identifier is the row's slot, so the returned value is what `WM_COMMAND`
/// will carry back.
fn storeRoute(
    routes: []Route,
    used: *usize,
    model: MenuItem,
    live: EvaluatedItem,
    parent: win.Hmenu,
    position: win.Dword,
) win.Dword {
    routes[used.* + 1] = .{
        .item = live,
        .explicit_enabled = model.explicit_enabled,
        .explicit_checked = model.explicit_checked,
        .parent = parent,
        .position = position,
    };
    const command: win.Dword = @intCast(first_command + used.*);
    used.* += 1;
    return command;
}

/// The `MFS_*` state for one evaluated row.
///
/// A disabled row is `MFS_DISABLED`, which the SDK defines as the greyed *and*
/// unclickable combination. A separate `MFS_GRAYED` row stays clickable and
/// would let a user activate an action the registry said is unavailable, so the
/// two are never used apart.
fn stateFlags(state: EvaluatedItem) u32 {
    var flags: u32 = 0;
    if (!state.enabled) flags |= win.mfs_disabled;
    if (state.checked) flags |= win.mfs_checked;
    return flags;
}

/// The live native menu attached to one window.
///
/// The `HMENU` becomes the window's menu and is therefore owned by the window,
/// so `deinit` detaches it first. That order is the one Windows requires: a
/// destroyed menu still referenced by a window is a dangling handle in the
/// shell, and `deinit` runs before the caller destroys the window.
///
/// Its attachments come off before the `HMENU` does. A `Subclass` record names
/// this menu and the window procedure resolves routes through that record, so
/// a menu released while one of them is still installed would hand the
/// platform a route table and an evaluation arena that are already gone. That
/// retirement happens here rather than in the caller's teardown order, so no
/// order a caller registers its `defer`s in can free a menu under a live
/// window procedure.
pub const WindowMenu = struct {
    window: sdl3.video.Window,
    menu: NativeMenu,

    /// Attach `menu` to `window` as its menu bar.
    ///
    /// The `HWND` comes from SDL's own window property, so SDL stays the owner
    /// of the window and no handle is taken from a graphics API.
    pub fn init(window: sdl3.video.Window, incoming: NativeMenu) Error!WindowMenu {
        var menu = incoming;
        // The menu is the caller's by value, so an attach that fails must give
        // it back rather than drop it: its route table and the evaluation arena
        // inside it have no other owner.
        errdefer menu.deinit();
        if (comptime !win.is_windows) {
            return error.NativeMenuRefused;
        }
        const hwnd = hwndOf(window) orelse return error.NativeMenuRefused;
        if (!win.SetMenu(hwnd, menu.native)) return error.NativeMenuRefused;
        // A menu attached but not drawn leaves the window without a bar until
        // something else happens to redraw it, so the bar is asked for.
        _ = win.DrawMenuBar(hwnd);
        return .{ .window = window, .menu = menu };
    }

    /// Detach the menu from its window, retire what routed for it, and release
    /// everything it owns.
    ///
    /// THE ATTACHMENTS GO FIRST, always, whatever order the caller tears down
    /// in. Every attachment naming this menu is retired here, before the
    /// `HMENU` is let go and before the route table and the evaluation arena
    /// are released, so the window procedure cannot resolve a row out of
    /// storage that no longer exists. A caller's `detach` after this is a
    /// no-op rather than a second write of a live address, which is what makes
    /// a host that releases its menu first correct rather than merely lucky.
    pub fn deinit(self: *WindowMenu) void {
        retireAttachments(self);
        if (comptime win.is_windows) {
            if (hwndOf(self.window)) |hwnd| _ = win.SetMenu(hwnd, null);
        }
        self.menu.deinit();
        self.* = undefined;
    }

    /// Dispatch a `WM_COMMAND` the window received, through the shared bridge.
    ///
    /// Which messages are rows at all is decided by `commandCode`, the same
    /// decoder the installed window procedure uses, so a host that forwards a
    /// `WM_COMMAND` here and the platform's own delivery cannot disagree about
    /// what a menu command is.
    ///
    /// The dispatch belongs to the bridge: it re-checks availability against the
    /// action registry and, for a system action, calls the host's system
    /// handler. A row the registry no longer allows answers `unavailable`, which
    /// is exactly what an in-app click would answer, so a native menu cannot
    /// reach an action the model has closed.
    ///
    /// The row handed to the bridge is rebuilt from the route, so the action
    /// name and payload it dispatches are the evaluation's bytes and not the
    /// caller's. A host whose bar was scratch storage freed the moment the menu
    /// was built gets the same click here as one that kept its strings.
    pub fn handleCommand(
        self: *WindowMenu,
        bridge: *MenuActionBridge,
        wparam: win.Wparam,
        tree: *const nogui.WidgetTree,
        focus: ?nogui.WidgetId,
    ) !nogui.action.Result {
        if (comptime !win.is_windows) return .unavailable;
        const code = commandCode(wparam) orelse return .unavailable;
        const route = self.menu.routeFor(code) orelse return .unavailable;
        return bridge.dispatchItem(route.modelRow(), tree, focus);
    }

    /// Move every route onto a newer evaluation, then write its states into the
    /// live `HMENU`.
    ///
    /// Called on `WM_INITMENUPOPUP`, the last moment before Windows draws the
    /// popup, and whenever the host's focused context changes. Each row is
    /// addressed by the `HMENU` and position it was built at, so a refresh
    /// writes into exactly the rows the command identifiers already point at
    /// and the route table stays valid.
    ///
    /// The order is the whole lifetime rule, and it runs in three steps. The
    /// bar is CHECKED against the rows this menu routes before anything is
    /// touched, because a bar that fails the check must leave the installed one
    /// in place. Every route is then repointed onto the incoming arena while
    /// the previous arena is still alive, and only after the whole table points
    /// at storage this menu owns is the previous evaluation released. Freeing it
    /// first would leave every route naming released bytes, and a click would
    /// dispatch an action name read out of a freed arena.
    ///
    /// A bar whose command rows are not the ones this menu was built from is
    /// refused as a whole rather than partly written. Pairing a shorter list
    /// against a longer one is how a refresh ends up greying one row and
    /// checking the next, and a menu whose states belong to other rows is
    /// worse than one whose states are a frame old. The same refusal covers a
    /// row that changed its action, because repointing it would redirect a click
    /// away from the action whose label is drawn next to it. A refusal releases
    /// the bar that was handed over, because this function owns it from the
    /// moment it is called, and the installed evaluation keeps owning every
    /// route string.
    ///
    /// The drawn TEXT is the text this menu was built with: a refresh rewrites
    /// state, not labels. A host that changes a label rebuilds the menu.
    pub fn refresh(self: *WindowMenu, incoming: EvaluatedMenuBar) void {
        var evaluated = incoming;
        if (comptime !win.is_windows) {
            // Nothing is refreshed, so the arena the caller handed over is
            // released here rather than dropped on the floor.
            evaluated.deinit();
            return;
        }
        const routes = self.menu.routes[1..];
        if (!routesCarry(routes, evaluated.menus)) {
            // Refused as a whole. The installed evaluation still owns every
            // route string, so the menu keeps routing what it routed before,
            // and the bar handed over is released rather than leaked.
            evaluated.deinit();
            return;
        }
        // Every route moves onto the incoming arena while the previous one is
        // still alive. The whole table is repointed first and the old arena is
        // released only afterwards, so no route is ever left naming freed bytes.
        var pointer: RouteWriter = .{ .routes = routes };
        var cursor: usize = 0;
        for (evaluated.menus) |live| eachCommand(RouteWriter.repoint, live, &cursor, &pointer);
        if (self.menu.evaluated) |*current| current.deinit();
        self.menu.evaluated = evaluated;

        var writer: StateWriter = .{ .routes = routes };
        for (evaluated.menus) |live| eachCommand(writeState, live, &writer.next, &writer);
    }
};

/// Whether `bar` re-evaluates exactly the rows `routes` addresses.
///
/// The count alone is not enough. Two bars can carry the same number of
/// commands and disagree about which is which, and a refresh that repointed one
/// into the other would send every click to the wrong action -- which is why the
/// check compares identity per row and not just a length.
fn routesCarry(routes: []const Route, bar: []const EvaluatedMenu) bool {
    if (routes.len != commandCount(bar)) return false;
    var check: RouteCheck = .{ .routes = routes };
    var cursor: usize = 0;
    for (bar) |menu| eachCommand(RouteCheck.compare, menu, &cursor, &check);
    return check.matched;
}

/// Whether a held route and a fresh evaluation name the same command.
///
/// The id, the kind and the action identity are compared. Labels and payloads
/// are deliberately not: a payload that changes between evaluations is the host
/// passing new data to the same action, and a label that changes is a host that
/// wants a rebuild. The action is what decides where a click lands, so it is
/// what must not move underneath the row.
fn sameRow(held: EvaluatedItem, fresh: EvaluatedItem) bool {
    if (held.id != fresh.id) return false;
    if (held.kind != fresh.kind) return false;
    if (held.system_action != fresh.system_action) return false;
    const held_name = held.action_name orelse return fresh.action_name == null;
    const fresh_name = fresh.action_name orelse return false;
    return std.mem.eql(u8, held_name, fresh_name);
}

/// The one row comparison `routesCarry` runs, addressed by the command
/// identifier the walk hands out.
const RouteCheck = struct {
    routes: []const Route,
    matched: bool = true,

    fn compare(context: *anyopaque, command: usize, item: EvaluatedItem) void {
        const self: *RouteCheck = @ptrCast(@alignCast(context));
        if (command >= self.routes.len) {
            self.matched = false;
            return;
        }
        if (!sameRow(self.routes[command].item, item)) self.matched = false;
    }
};

/// The one route rewrite a refresh makes, addressed by the command identifier
/// the walk hands out.
///
/// It assigns the fresh row whole rather than copying field by field, so a
/// string this file learns about later cannot be left behind pointing into the
/// arena being released. The route's own scalars are untouched: they came from
/// the model at build time and describe the row, not this evaluation.
const RouteWriter = struct {
    routes: []Route,

    fn repoint(context: *anyopaque, command: usize, item: EvaluatedItem) void {
        const self: *RouteWriter = @ptrCast(@alignCast(context));
        if (command >= self.routes.len) return;
        self.routes[command].item = item;
    }
};

/// The command identifier a `WM_COMMAND` names, or null when the message is
/// not a plain menu command.
///
/// The high word carries a notification code such as `BN_CLICKED`, so a
/// message that carries one came from a control rather than from a row of the
/// menu. Resolving it anyway hands that control's command to whichever row
/// happens to share the low word, which is a different action from the one the
/// control asked for. Only a zero high word is a menu command, and both the
/// procedure and a direct caller decode through here so they cannot disagree
/// about which messages are rows.
fn commandCode(wparam: win.Wparam) ?win.Dword {
    const code: win.Dword = @truncate(wparam);
    if ((code >> 16) != 0) return null;
    return code;
}

/// How many command rows a bar holds.
///
/// This is the same walk `build` performs, over the same tree, so the count it
/// produces is the number of identifiers `build` handed out and the number of
/// slots in the route table.
fn commandCount(bar: []const EvaluatedMenu) usize {
    var total: usize = 0;
    for (bar) |menu| total += commandRowsIn(menu);
    return total;
}

fn commandRowsIn(menu: EvaluatedMenu) usize {
    var total: usize = 0;
    for (menu.items) |item| switch (item.kind) {
        .action, .system_action => total += 1,
        .separator => {},
        // A submenu header is not a command, and its children are counted where
        // the header appears, which is the order `appendRows` numbers them in.
        .submenu => {
            if (item.submenu) |sub| {
                total += commandRowsIn(.{ .title = "", .items = sub });
            }
        },
    };
    return total;
}

/// Walk the evaluated bar the way `appendRows` walked the model, handing only
/// the rows that carry a command to `visit`, each with the identifier it was
/// given.
///
/// Separators and submenu headers are drawn by the shell and cannot be
/// commanded, and `appendRows` gave them no identifier, so they are skipped
/// here as well. A walk that kept them would pair row `n` of the route table
/// with row `n` of a longer list, and every state after the first separator
/// would land on the wrong `HMENU` row.
fn eachCommand(
    comptime visit: fn (context: *anyopaque, command: usize, item: EvaluatedItem) void,
    menu: EvaluatedMenu,
    cursor: *usize,
    context: *anyopaque,
) void {
    for (menu.items) |item| switch (item.kind) {
        .action, .system_action => {
            visit(context, cursor.*, item);
            cursor.* += 1;
        },
        .separator => {},
        .submenu => if (item.submenu) |sub|
            eachCommand(visit, .{ .title = "", .items = sub }, cursor, context),
    };
}

/// The one `HMENU` write a refresh makes, addressed by the route the row was
/// built at.
const StateWriter = struct {
    routes: []const Route,
    next: usize = 0,
};

fn writeState(context: *anyopaque, command: usize, item: EvaluatedItem) void {
    const self: *StateWriter = @ptrCast(@alignCast(context));
    // The count was checked before the walk began, so this cannot run past the
    // table; the bound is here because a window procedure must not trust a
    // length it did not just verify.
    if (command >= self.routes.len) return;
    const route = self.routes[command];
    var info: win.MenuItemInfoW = std.mem.zeroes(win.MenuItemInfoW);
    info.cbSize = @sizeOf(win.MenuItemInfoW);
    info.fMask = win.miim_state;
    info.fState = stateFlags(item);
    // `bNewItem = 0` addresses by position, which is what the route recorded
    // when the row was appended.
    _ = win.SetMenuItemInfoW(route.parent, route.position, 0, &info);
}

// ── the window procedure ─────────────────────────────

/// What one delivered `WM_COMMAND` produced.
///
/// A window procedure has no return value to carry an answer in, so the answer
/// reaches the host through this instead. The three cases stay apart because
/// they are three different facts: a row the bridge ran, an identifier that
/// named no row of this menu, and a handler that failed. Reporting a failed
/// handler as a refusal would tell a host its action was unavailable when it
/// was, in fact, reachable and broken.
pub const CommandOutcome = union(enum) {
    answered: nogui.action.Result,
    /// The identifier named no row of this menu, or carried a notification
    /// code. Nothing was dispatched.
    unrouted,
    /// The action handler itself failed. The menu row was real and the
    /// registry ran it.
    handler_failed: anyerror,
};

/// The live answer a delivered `WM_COMMAND` needs, read at the moment the
/// message arrives.
///
/// A menu click is delivered on the thread that owns the window, inside the
/// window procedure, long after the menu was built. The tree it has to
/// dispatch against is the App's CURRENT committed tree and the focus is the
/// CURRENT focus, and both were different when `build` ran, so they are read
/// through the context here rather than captured. A command resolved against
/// a captured tree would run against a frame that is no longer on screen.
pub const CommandTarget = struct {
    /// The owner of the bridge and of whatever the two callbacks need. It has
    /// to outlive the attachment: the window procedure reaches it through this
    /// pointer for as long as the procedure is installed.
    context: ?*anyopaque = null,
    /// The bridge a menu row dispatches through. The same bridge the host
    /// hands to the in-app menu, so a native click and a widget activation
    /// reach one registry.
    bridge: *MenuActionBridge,
    /// The App's current committed tree. Returns the live tree pointer, not a
    /// copy: the registry resolves the action against the nodes that exist.
    tree: *const fn (?*anyopaque) *const nogui.WidgetTree,
    /// The current focused widget, read at the same moment as the tree.
    focus: *const fn (?*anyopaque) ?nogui.WidgetId,
    /// Told what each delivered command produced, on the thread that delivered
    /// it. Null when the host wants the dispatch and nothing else.
    on_result: ?*const fn (?*anyopaque, command: win.Dword, outcome: CommandOutcome) void = null,
    /// Re-evaluate before the shell draws a popup. `WM_INITMENUPOPUP` is the
    /// last moment at which a native menu's enablement can be correct, so a
    /// host that does not hook it has a menu whose greying is a frame old.
    /// The argument is the popup `HMENU` the message names.
    on_init_menu_popup: ?*const fn (?*anyopaque, popup: win.Hmenu) void = null,
};

/// The live attachments in this process, in the order they were made.
///
/// Windows stores a window procedure as a bare address and calls it with
/// nothing but the message, so the record that says WHICH menu owns this
/// window cannot travel in the signature. This is where it is found, and it is
/// a list of the attachments rather than a runtime of its own: it holds no
/// state, answers no query, and is empty again once each attachment detaches.
///
/// The list is touched only on the thread that created the window, which is the
/// thread its procedure runs on, so it needs no lock. A host that creates
/// windows on two threads gets one list per process and an attachment is
/// reached from its own thread.
var attachments: ?*Subclass = null;

/// The procedure Windows calls once this file has been installed.
///
/// Every message reaches it and every message is forwarded, because the
/// procedure it replaced is the one that knows how to size, activate, close and
/// run the menu loop for this window. The two messages it acts on are acted on
/// BEFORE the forward, so the dispatch is finished by the time the shell's own
/// handling of the same message runs.
fn procedure(
    hwnd: win.Hwnd,
    message: u32,
    wparam: win.Wparam,
    lparam: win.Lparam,
) callconv(.winapi) win.Lresult {
    const hook = find(hwnd) orelse return win.DefWindowProcW(hwnd, message, wparam, lparam);
    if (message == win.wm_command) {
        dispatchCommand(hook, wparam);
    } else if (message == win.wm_initmenupopup) {
        // Counted whether or not the host re-evaluates: the message arriving
        // is the fact, and a run that hooks nothing here still learns that the
        // shell asked for a refresh this attachment could have made.
        hook.popups += 1;
        if (hook.target.on_init_menu_popup) |reopen| {
            // The popup handle arrives in `wParam`; the message is forwarded
            // either way, so nothing is consumed from it.
            reopen(hook.target.context, @ptrFromInt(wparam));
        }
    }
    return win.CallWindowProcW(hook.previous, hwnd, message, wparam, lparam);
}

/// Turn one delivered `WM_COMMAND` into a call on the bridge.
fn dispatchCommand(hook: *Subclass, wparam: win.Wparam) void {
    const report = hook.target.on_result;
    const context = hook.target.context;
    // Every message this window was handed is counted, including one that names
    // no row: a menu the shell sent a command to and this attachment refused is
    // a different thing from a menu nobody touched, and only the count tells
    // them apart.
    hook.commands += 1;
    const code: win.Dword = @truncate(wparam);
    // A notification code, or an identifier this menu never assigned, is
    // reported as unrouted. The message is still forwarded below, because the
    // procedure it replaced is the one that knows what a control's command
    // means.
    const resolved = commandCode(wparam) orelse {
        if (report) |tell| tell(context, code, .unrouted);
        return;
    };
    hook.last_command = resolved;
    if (hook.menu.menu.routeFor(resolved) == null) {
        if (report) |tell| tell(context, code, .unrouted);
        return;
    }
    // The tree and the focus are read here, on the message's own thread, and
    // not when the attachment was made: the command is resolved against the
    // frame the window is showing now.
    const tree = hook.target.tree(context);
    const focus = hook.target.focus(context);
    const result = hook.menu.handleCommand(hook.target.bridge, wparam, tree, focus) catch |err| {
        if (report) |tell| tell(context, code, .{ .handler_failed = err });
        return;
    };
    if (report) |tell| tell(context, code, .{ .answered = result });
}

/// The attachment that owns this window, or null when the window is not one of
/// this file's.
fn find(hwnd: win.Hwnd) ?*Subclass {
    var cursor = attachments;
    while (cursor) |hook| : (cursor = hook.next) {
        if (hook.hwnd == hwnd) return hook;
    }
    return null;
}

/// This directory's window procedure, installed on one window.
///
/// The record is owned by the caller and must stay at one address for as long
/// as the procedure is installed: Windows holds the ADDRESS of `procedure`, and
/// that address is matched back to this record on every message. It is
/// therefore a value the caller keeps in place, and `detach` puts the previous
/// procedure back before the caller is allowed to move or release anything.
///
/// It must also be installed on the thread that created the window, which is
/// the thread its procedure runs on, and detached before the window is
/// destroyed. A procedure that outlives its window is a call into freed
/// memory on the first message the window manager sends during teardown.
pub const Subclass = struct {
    /// The menu this attachment routes for. The `HMENU` and the route table
    /// belong to it, so the procedure needs no copy of either.
    menu: *WindowMenu,
    hwnd: win.Hwnd,
    /// The procedure Windows had before this one.
    previous: win.Wndproc,
    target: CommandTarget,
    /// Commands this attachment has been handed, and the last identifier it
    /// resolved. They are how a host tells a menu nobody clicked from a menu
    /// whose clicks went somewhere else, and they are written and read on the
    /// window's own thread.
    commands: u32 = 0,
    last_command: win.Dword = 0,
    /// Popups the shell asked to have refreshed, from `WM_INITMENUPOPUP`.
    popups: u32 = 0,
    next: ?*Subclass = null,
    attached: bool = true,

    /// Put this directory's procedure on the window and return the record.
    ///
    /// The record is returned rather than heap allocated, so the caller keeps
    /// the storage and this function keeps no reference to it beyond the one
    /// the procedure needs. It is returned by pointer because a window
    /// procedure reaches its owner through an address, and that address has to
    /// be the address the caller holds.
    ///
    /// ONE WINDOW, ONE RECORD. A window already carrying an attachment of this
    /// directory's is refused by name, and the refusal comes before `slot` is
    /// filled and before any native call, so a refused attach leaves the
    /// caller's storage untouched rather than half published.
    pub fn attach(slot: *Subclass, menu: *WindowMenu, target: CommandTarget) Error!*Subclass {
        if (comptime !win.is_windows) return error.NoNativeWindow;
        const hwnd = hwndOf(menu.window) orelse return error.NoNativeWindow;
        if (find(hwnd) != null) return error.SubclassAlreadyAttached;
        slot.* = .{
            .menu = menu,
            .hwnd = hwnd,
            // SAFETY: `previous` holds the procedure this one replaced, and
            // `SetWindowLongPtrW` below stores that answer before any code
            // reads it. The refusal path poisons the whole record instead, so
            // no caller can reach this one half-filled.
            .previous = undefined,
            .target = target,
        };
        const previous = win.SetWindowLongPtrW(
            hwnd,
            win.gwl_wndproc,
            @bitCast(@intFromPtr(&procedure)),
        );
        // A zero return is both "there was no previous procedure" and "the
        // call failed", and only the last error tells them apart.
        if (previous == 0 and win.lastError() != win.error_success) {
            // SAFETY: the swap failed, so this record was never published --
            // `attachments` does not receive it until the call below has
            // answered -- and poisoning it leaves nothing reachable for the
            // window procedure to call into.
            slot.* = undefined;
            return error.SubclassRefused;
        }
        slot.previous = @ptrFromInt(@as(usize, @bitCast(previous)));
        slot.next = attachments;
        attachments = slot;
        return slot;
    }

    /// Put the window's own procedure back and forget this attachment.
    ///
    /// Calling it twice is a no-op, so the natural `defer` after an explicit
    /// detach is safe rather than a second write of a live address.
    ///
    /// Two refusals, and this record is left unreachable by both. A handle
    /// that is no longer a window cannot be given a procedure at all, and
    /// reaching into it anyway is how a detach becomes the crash it was meant
    /// to prevent. A window now running someone ELSE's procedure is a window
    /// this record no longer owns, and writing `previous` over it would
    /// replace a procedure the host installed after this one with the one it
    /// displaced. Refusing that write is safe rather than a leak, because the
    /// record is found only through this directory's own procedure: once it is
    /// off the list, a message that still reaches `procedure` resolves this
    /// window to nothing and is answered by `DefWindowProcW`. So neither the
    /// refused restore nor a restore that did not take leaves a live hook
    /// naming a menu that is about to be released.
    pub fn detach(self: *Subclass) void {
        if (!self.attached) return;
        self.attached = false;
        if (comptime win.is_windows) {
            if (window_interop.isWindow(self.hwnd) and self.installed()) {
                _ = win.SetWindowLongPtrW(
                    self.hwnd,
                    win.gwl_wndproc,
                    @bitCast(@intFromPtr(self.previous)),
                );
            }
        }
        unlink(self);
    }

    /// Whether the window manager still holds this directory's procedure.
    ///
    /// Read back through `GWL_WNDPROC` rather than assumed from `attached`, so
    /// an answer that says the window is running someone else's procedure is
    /// visible as one.
    pub fn installed(self: *const Subclass) bool {
        if (comptime !win.is_windows) return false;
        if (!window_interop.isWindow(self.hwnd)) return false;
        const current = win.GetWindowLongPtrW(self.hwnd, win.gwl_wndproc);
        return @as(usize, @bitCast(current)) == @intFromPtr(&procedure);
    }
};

fn unlink(hook: *Subclass) void {
    var slot: *?*Subclass = &attachments;
    while (slot.*) |current| {
        if (current == hook) {
            slot.* = current.next;
            return;
        }
        slot = &current.next;
    }
}

/// Retire every live attachment that routes for `menu`.
///
/// This is what makes a menu unreachable, because the window procedure reaches
/// a menu only through the record `find` answers for the message's window.
/// Retiring them here rather than in the caller's teardown is what makes the
/// order a caller registers its `defer`s in irrelevant.
///
/// The successor is read before the detach runs, because detaching unlinks the
/// record and rewrites the link this walk is standing on.
fn retireAttachments(menu: *WindowMenu) void {
    var cursor = attachments;
    while (cursor) |hook| {
        const next = hook.next;
        if (hook.menu == menu) hook.detach();
        cursor = next;
    }
}

test "api-w23 windows native menu counts only command rows" {
    // Separators and submenu headers are not commands, so they must not consume
    // an identifier. A table sized as if they did would leave the last real row
    // unroutable.
    const items = [_]MenuItem{
        .{ .id = 1, .label = "File", .kind = .submenu, .submenu = &.{
            .{ .id = 2, .label = "Open", .kind = .action, .action_name = "file.open" },
            .{ .kind = .separator },
            .{ .id = 3, .label = "Quit", .kind = .system_action, .system_action = .quit },
        } },
        .{ .id = 4, .label = "Edit", .kind = .submenu, .submenu = &.{
            .{ .id = 5, .label = "Undo", .kind = .action, .action_name = "edit.undo" },
            .{ .kind = .separator },
            .{ .id = 6, .label = "Paste", .kind = .action, .action_name = "edit.paste" },
        } },
    };
    // Four commands: Open, Quit, Undo and Paste. Two submenu headers and four
    // separators contribute nothing.
    try std.testing.expectEqual(@as(usize, 4), countItems(&items));

    // A submenu with no rows has no command in it either, and `build` refuses
    // it rather than attaching a popup that opens onto nothing.
    const empty_submenu = [_]MenuItem{
        .{ .id = 1, .label = "File", .kind = .submenu, .submenu = &.{} },
    };
    try std.testing.expectEqual(@as(usize, 0), countItems(&empty_submenu));
}

test "api-w23 windows menu state maps a disabled row to greyed and unclickable" {
    // A row the action registry refused must be unclickable, not merely drawn in
    // grey, or a user can activate an action the model says is unavailable.
    const disabled: EvaluatedItem = .{
        .id = 1,
        .label = "Undo",
        .enabled = false,
        .checked = false,
        .kind = .action,
    };
    try std.testing.expectEqual(win.mfs_disabled, stateFlags(disabled));
    try std.testing.expectEqual(@as(u32, 0), stateFlags(disabled) & win.mfs_checked);

    const checked: EvaluatedItem = .{
        .id = 2,
        .label = "Wrap",
        .enabled = true,
        .checked = true,
        .kind = .action,
    };
    try std.testing.expectEqual(win.mfs_checked, stateFlags(checked));
    try std.testing.expectEqual(@as(u32, 0), stateFlags(checked) & win.mfs_disabled);
}

test "api-w23 windows global menu availability is target dependent" {
    // A build that cannot attach a window menu says so, and does not fall back
    // to an in-app bar pretending to be native.
    if (comptime !win.is_windows) {
        try std.testing.expect(!hasNativeGlobalMenu());
        try std.testing.expect(hwndOf(.{ .value = @ptrFromInt(0x1234) }) == null);
    }
}

/// One evaluated bar whose rows live in its own arena, which is what the
/// bridge hands a native menu builder.
fn evaluatedBar(gpa: std.mem.Allocator) std.mem.Allocator.Error!EvaluatedMenuBar {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const items = try arena.allocator().alloc(EvaluatedItem, 1);
    items[0] = .{
        .id = 1,
        .label = "Open",
        .enabled = true,
        .checked = false,
        .kind = .action,
        .action_name = "file.open",
    };
    const evaluated = try arena.allocator().alloc(EvaluatedMenu, 1);
    evaluated[0] = .{ .title = "File", .items = items };
    return .{ .menus = evaluated, .arena = arena };
}

test "api-w23 a refused windows menu build gives the evaluation back" {
    // The evaluation is an arena the caller handed over by value, and it is the
    // menu that owns it from that point. A refusal that dropped it would leak
    // the arena on every call, and off Windows every call is a refusal, so a
    // host that builds a menu bar per frame would leak without bound. The
    // caller is left with nothing it could release it with, which is the whole
    // reason the refusal has to.
    if (comptime !win.is_windows) {
        const bar = try evaluatedBar(std.testing.allocator);
        const model: MenuBar = .{ .menus = &.{
            .{ .title = "File", .items = &.{
                .{ .id = 1, .label = "Open", .kind = .action, .action_name = "file.open" },
            } },
        } };
        try std.testing.expectError(
            error.NativeMenuRefused,
            build(std.testing.allocator, model, bar),
        );
    }
}

test "api-w23 a command identifier resolves to the row the adapter numbered" {
    // A row's slot in the table IS its identifier, so this is an index and not
    // an offset. Decoding it as an offset hands the first command the unused
    // zero slot -- a row with no action name, which dispatches to nothing --
    // and every later command the row before it, so a menu whose Quit row runs
    // the Open action is what an off-by-one table produces.
    const parent: win.Hmenu = @ptrFromInt(0x1000);
    var table = [_]Route{
        // The unused zero slot. Windows sends identifier zero for "no command",
        // so nothing is ever stored here and nothing may resolve to it.
        .{
            .item = .{
                .id = 0,
                .label = "",
                .enabled = false,
                .checked = false,
                .kind = .action,
            },
            .explicit_enabled = null,
            .explicit_checked = null,
            .parent = parent,
            .position = 0,
        },
        .{
            .item = .{
                .id = 2,
                .label = "Open",
                .enabled = true,
                .checked = false,
                .kind = .action,
                .action_name = "file.open",
            },
            .explicit_enabled = null,
            .explicit_checked = null,
            .parent = parent,
            .position = 0,
        },
        .{
            .item = .{
                .id = 3,
                .label = "Quit",
                .enabled = true,
                .checked = false,
                .kind = .system_action,
                .system_action = .quit,
            },
            .explicit_enabled = null,
            .explicit_checked = null,
            .parent = parent,
            .position = 1,
        },
    };
    const menu: NativeMenu = .{
        .gpa = std.testing.allocator,
        .native = @ptrFromInt(0x2000),
        .routes = &table,
        .evaluated = null,
    };

    const first = menu.routeFor(1).?;
    try std.testing.expectEqualStrings("file.open", first.item.action_name.?);
    try std.testing.expectEqual(@as(win.Dword, 0), first.position);
    const second = menu.routeFor(2).?;
    try std.testing.expectEqual(menus.MenuItemKind.system_action, second.item.kind);
    try std.testing.expectEqual(@as(win.Dword, 1), second.position);

    // "No command" and an identifier this menu never assigned both name
    // nothing, and neither may fall back onto a row.
    try std.testing.expect(menu.routeFor(0) == null);
    try std.testing.expect(menu.routeFor(3) == null);
    try std.testing.expect(menu.routeFor(0x7FFE) == null);

    // A notification code in the high word is a control's command, not a row,
    // and is refused rather than resolved to whichever row shares the low word.
    try std.testing.expectEqual(@as(?win.Dword, 2), commandCode(2));
    try std.testing.expect(commandCode(@as(win.Wparam, 1) << 16 | 2) == null);
}

test "api-w23 a refresh pairs each command row with its own state" {
    // A refresh writes enablement and check state into the `HMENU` rows the
    // command table points at, so its walk has to visit exactly the rows
    // `build` numbered. Keeping the separators and the submenu headers in that
    // walk shifts every state after the first of them onto the next row, which
    // greys one command and checks the one below it.
    const separator: EvaluatedItem = .{
        .id = 0,
        .label = "",
        .enabled = true,
        .checked = false,
        .kind = .separator,
    };
    const file_rows = [_]EvaluatedItem{
        .{
            .id = 2,
            .label = "Open",
            .enabled = true,
            .checked = false,
            .kind = .action,
            .action_name = "file.open",
        },
        separator,
        .{
            .id = 3,
            .label = "Quit",
            .enabled = true,
            .checked = false,
            .kind = .system_action,
            .system_action = .quit,
        },
    };
    const edit_rows = [_]EvaluatedItem{
        .{
            .id = 5,
            .label = "Undo",
            .enabled = false,
            .checked = false,
            .kind = .action,
            .action_name = "edit.undo",
        },
        separator,
        .{
            .id = 6,
            .label = "Paste",
            .enabled = true,
            .checked = true,
            .kind = .action,
            .action_name = "edit.paste",
        },
    };
    const bar = [_]EvaluatedMenu{
        .{
            .title = "File",
            .items = &.{.{
                .id = 1,
                .label = "File",
                .enabled = true,
                .checked = false,
                .kind = .submenu,
                .submenu = &file_rows,
            }},
        },
        .{
            .title = "Edit",
            .items = &.{.{
                .id = 4,
                .label = "Edit",
                .enabled = true,
                .checked = false,
                .kind = .submenu,
                .submenu = &edit_rows,
            }},
        },
    };

    var collected: Collected = .{};
    var cursor: usize = 0;
    for (&bar) |menu| eachCommand(Collected.push, menu, &cursor, &collected);

    // The identifiers arrive as one unbroken run from one, so slot `n` of the
    // route table is the row the walk reports at `n`.
    try std.testing.expect(collected.in_order);
    try std.testing.expectEqual(@as(usize, 4), collected.count);
    try std.testing.expectEqualStrings("Open", collected.labels[0]);
    try std.testing.expectEqualStrings("Quit", collected.labels[1]);
    try std.testing.expectEqualStrings("Undo", collected.labels[2]);
    try std.testing.expectEqualStrings("Paste", collected.labels[3]);
    // The states are the ones each command row carries, so the disabled Undo
    // row and the checked Paste row land on themselves and not on each other.
    try std.testing.expect(!collected.enabled[2]);
    try std.testing.expect(collected.checked[3]);

    // The count is the guard `refresh` refuses on, and it is the same count
    // `build` produced identifiers from: four commands out of six rows.
    try std.testing.expectEqual(@as(usize, 4), commandCount(&bar));
    const model = [_]MenuItem{
        .{ .id = 1, .label = "File", .kind = .submenu, .submenu = &.{
            .{ .id = 2, .label = "Open", .kind = .action, .action_name = "file.open" },
            .{ .kind = .separator },
            .{ .id = 3, .label = "Quit", .kind = .system_action, .system_action = .quit },
        } },
        .{ .id = 4, .label = "Edit", .kind = .submenu, .submenu = &.{
            .{ .id = 5, .label = "Undo", .kind = .action, .action_name = "edit.undo" },
            .{ .kind = .separator },
            .{ .id = 6, .label = "Paste", .kind = .action, .action_name = "edit.paste" },
        } },
    };
    try std.testing.expectEqual(countItems(&model), commandCount(&bar));
}

/// What one refresh walk produced, in the order it produced it.
const Collected = struct {
    labels: [8][]const u8 = @splat(""),
    enabled: [8]bool = @splat(false),
    checked: [8]bool = @splat(false),
    count: usize = 0,
    /// Whether every visit arrived under the identifier the previous one used
    /// plus one. A walk that kept the separators would break it on the first
    /// one, which is the whole failure this guards.
    in_order: bool = true,

    fn push(context: *anyopaque, command: usize, item: EvaluatedItem) void {
        const self: *Collected = @ptrCast(@alignCast(context));
        if (command != self.count) self.in_order = false;
        if (command < self.labels.len) {
            self.labels[command] = item.label;
            self.enabled[command] = item.enabled;
            self.checked[command] = item.checked;
        }
        self.count += 1;
    }
};

// The seam a headless build cannot reach, and what it costs to be honest
// about it.
//
// `appendRows` needs a real `HMENU`, so the whole of `build` is refused off
// Windows and no amount of headless running reaches the store. The seam is
// `storeRoute`, which is the only place this adapter decides WHO owns a
// route's strings, and it is driven here exactly as `appendRows` drives it:
// with a model row and the evaluated row that model row was evaluated into.
// So this test proves the ownership and the routing, and it says nothing about
// `CreatePopupMenu` or `InsertMenuItemW`, which no headless run touches. The
// `HMENU` here is a fabricated handle stored in the table and never handed to
// a call.
test "api-w23 a windows route keeps routing after the caller's bar is gone" {
    const Draft = struct {
        const Self = @This();

        calls: u32 = 0,
        last: u32 = 0,

        fn save(self: *Self, value: *const u32, _: *nogui.Session) !void {
            self.calls += 1;
            self.last = value.*;
        }
        fn available(_: *const Self, _: *nogui.Session) nogui.action.Availability {
            return .available;
        }
    };

    var session = try nogui.Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var registry = try nogui.action.Registry.init(std.testing.allocator, &session);
    defer registry.deinit();

    const SaveAs = nogui.action.Action(u32, "file.save-as");
    try registry.register(SaveAs);

    var initial: Draft = .{};
    var draft = try session.create(Draft, &initial);
    defer session.release(Draft, &draft) catch unreachable;

    const document: nogui.WidgetId = .{ .owner = 1, .slot = 900, .generation = 1 };
    var tree = nogui.WidgetTree.init(std.testing.allocator);
    defer tree.deinit();
    try tree.nodes.append(std.testing.allocator, .{
        .id = @fromBackingInt(@intCast(1)),
        .widget_id = document,
        .parent = .root,
        .kind = .{ .label = .{ .text = "document" } },
    });
    _ = try registry.bind(
        SaveAs,
        Draft,
        Draft.save,
        Draft.available,
        .{ .widget = document },
        draft.weak(),
    );

    var bridge = MenuActionBridge.init(&registry);

    // The model is scratch storage, the way a host that rebuilds its bar every
    // frame has it. Every string the row routes by is formatted into it,
    // INCLUDING the action name and the payload, so a route that borrowed them
    // would be dispatching released bytes.
    const scratch = try std.testing.allocator.alloc(u8, 128);
    const label = try std.fmt.bufPrint(scratch[0..32], "Save as draft", .{});
    const name = try std.fmt.bufPrint(scratch[32..64], "{s}", .{SaveAs.name});
    const payload = try std.fmt.bufPrint(scratch[64..80], "{d}", .{@as(u32, 41)});
    const items = [_]MenuItem{.{
        .id = 2,
        .label = label,
        .kind = .action,
        .action_name = name,
        .action_payload_json = payload,
    }};
    const titles = [_]menus.Menu{.{ .title = "File", .items = &items }};
    const bar: MenuBar = .{ .menus = &titles };

    var first = try bridge.evaluate(std.testing.allocator, bar, &tree, document);

    // The build that a Windows run performs: slot zero reserved, then one
    // stored row per command.
    const parent: win.Hmenu = @ptrFromInt(0x1000);
    var routes = try std.testing.allocator.alloc(Route, 2);
    defer std.testing.allocator.free(routes);
    routes[0] = .{
        .item = .{
            .id = 0,
            .label = "",
            .enabled = false,
            .checked = false,
            .kind = .action,
        },
        .explicit_enabled = null,
        .explicit_checked = null,
        .parent = parent,
        .position = 0,
    };
    var used: usize = 0;
    const command = storeRoute(
        routes,
        &used,
        items[0],
        first.menus[0].items[0],
        parent,
        0,
    );
    try std.testing.expectEqual(first_command, command);

    // The host has moved on. The next frame's text lands in the same buffer,
    // and then the buffer itself is gone.
    @memset(scratch, 'x');
    std.testing.allocator.free(scratch);

    // The row still names the action it was built for, out of bytes the menu
    // owns. A route holding the model row would read the scratch buffer here,
    // and the poisoning is what that read would show.
    const held = routes[command];
    try std.testing.expectEqualStrings("Save as draft", held.modelRow().label);
    try std.testing.expectEqualStrings("file.save-as", held.modelRow().action_name.?);
    try std.testing.expectEqualStrings("41", held.modelRow().action_payload_json.?);

    // And the click still lands on the model, carrying the payload the row was
    // evaluated with, rather than dispatching to nothing.
    try std.testing.expectEqual(nogui.action.Result.handled, try bridge.dispatchItem(
        held.modelRow(),
        &tree,
        document,
    ));
    const Ran = struct {
        fn run(value: *const Draft, out: *u32) !void {
            out.* = value.last;
        }
    };
    var seen: u32 = 0;
    try session.read(Draft, draft.weak(), &seen, Ran.run);
    try std.testing.expectEqual(@as(u32, 41), seen);

    // A REFRESH. The next frame's bar is new scratch storage again, and the
    // payload moves with the model. The check runs while the OLD evaluation is
    // still alive, which is the only time the held rows can be compared.
    const frame = try std.testing.allocator.alloc(u8, 128);
    defer std.testing.allocator.free(frame);
    const frame_label = try std.fmt.bufPrint(frame[0..32], "Save as draft", .{});
    const frame_name = try std.fmt.bufPrint(frame[32..64], "{s}", .{SaveAs.name});
    const frame_payload = try std.fmt.bufPrint(frame[64..80], "{d}", .{@as(u32, 43)});
    const frame_items = [_]MenuItem{.{
        .id = 2,
        .label = frame_label,
        .kind = .action,
        .action_name = frame_name,
        .action_payload_json = frame_payload,
    }};
    const frame_titles = [_]menus.Menu{.{ .title = "File", .items = &frame_items }};
    const frame_bar: MenuBar = .{ .menus = &frame_titles };

    var second = try bridge.evaluate(std.testing.allocator, frame_bar, &tree, document);
    defer second.deinit();

    try std.testing.expect(routesCarry(routes[1..], second.menus));

    // Every route moves onto the incoming arena, and only then is the previous
    // one released. Reversing these two steps is the use-after-free this order
    // exists to prevent: the table would keep naming a freed arena.
    var pointer: RouteWriter = .{ .routes = routes[1..] };
    var cursor: usize = 0;
    for (second.menus) |live| eachCommand(RouteWriter.repoint, live, &cursor, &pointer);
    first.deinit();

    // The row still routes after the arena it was built from is gone, and it
    // carries the NEW payload, because the repoint happened before the free.
    try std.testing.expectEqualStrings("43", routes[command].modelRow().action_payload_json.?);
    try std.testing.expectEqual(nogui.action.Result.handled, try bridge.dispatchItem(
        routes[command].modelRow(),
        &tree,
        document,
    ));
    try session.read(Draft, draft.weak(), &seen, Ran.run);
    try std.testing.expectEqual(@as(u32, 43), seen);

    // A bar that is NOT this menu's rows is refused, and the refusal keeps the
    // installed evaluation rather than swapping in one that does not match. A
    // bar of the right length naming a different action is the case a count
    // alone would wave through.
    const other_name = "file.save-all";
    const other_items = [_]MenuItem{.{
        .id = 2,
        .label = frame_label,
        .kind = .action,
        .action_name = other_name,
        .action_payload_json = frame_payload,
    }};
    const other_titles = [_]menus.Menu{.{ .title = "File", .items = &other_items }};
    const other_bar: MenuBar = .{ .menus = &other_titles };
    var other = try bridge.evaluate(std.testing.allocator, other_bar, &tree, document);
    defer other.deinit();
    try std.testing.expect(!routesCarry(routes[1..], other.menus));

    // Refused, so nothing moved: the route still dispatches the action it was
    // built for.
    try std.testing.expectEqualStrings("file.save-as", routes[command].modelRow().action_name.?);

    // A shorter bar is refused on the count alone, before any row is compared.
    const empty_titles = [_]menus.Menu{.{ .title = "File", .items = &.{} }};
    const empty_bar: MenuBar = .{ .menus = &empty_titles };
    var empty = try bridge.evaluate(std.testing.allocator, empty_bar, &tree, document);
    defer empty.deinit();
    try std.testing.expect(!routesCarry(routes[1..], empty.menus));
}

// The model's own overrides survive into the route, because a consumer that
// re-asks the bridge about a route must get what the model declared rather
// than a second opinion from the registry.
//
// The overrides are the one part of a route that is NOT the evaluation's: they
// are scalars the evaluation does not carry, so they are copied at build time
// and a refresh leaves them alone. A row the model pinned stays pinned.
test "api-w23 a windows route keeps the model's own overrides" {
    const parent: win.Hmenu = @ptrFromInt(0x1000);
    const model: MenuItem = .{
        .id = 7,
        .label = "Save as",
        .kind = .action,
        .action_name = "file.save-as",
        .explicit_enabled = false,
        .explicit_checked = true,
    };
    const live: EvaluatedItem = .{
        .id = 7,
        .label = "Save as",
        .enabled = true,
        .checked = false,
        .kind = .action,
        .action_name = "file.save-as",
    };

    // The evaluation is written by hand here to disagree with the model on
    // purpose: it reports the row as enabled and unchecked. That is what makes
    // the two halves of a route separable, and it is what `evaluate` produces
    // for a bar whose overrides the caller set on a DIFFERENT pass.
    var routes: [2]Route = @splat(.{ .item = .{
        .id = 0,
        .label = "",
        .enabled = false,
        .checked = false,
        .kind = .action,
    }, .explicit_enabled = null, .explicit_checked = null, .parent = parent, .position = 0 });
    var used: usize = 0;
    _ = storeRoute(&routes, &used, model, live, parent, 3);

    const route = routes[1];
    // The overrides came from the model, even though the evaluation this row
    // was built from says the opposite: a model that pins a row is stating a
    // fact the registry cannot know.
    try std.testing.expectEqual(@as(?bool, false), route.explicit_enabled);
    try std.testing.expectEqual(@as(?bool, true), route.explicit_checked);
    // The state the menu DRAWS is the evaluation's alone. This row's
    // evaluation says enabled and unchecked, so it draws neither greyed nor
    // ticked -- the model's overrides are not a second input to `stateFlags`,
    // because `evaluate` already folded them into the state it reported.
    try std.testing.expectEqual(@as(u32, 0), stateFlags(route.item));
    try std.testing.expectEqual(@as(u32, 0), stateFlags(route.item) & win.mfs_disabled);
    try std.testing.expectEqual(@as(u32, 0), stateFlags(route.item) & win.mfs_checked);

    const dispatched = route.modelRow();
    try std.testing.expectEqual(@as(u64, 7), dispatched.id);
    try std.testing.expectEqual(@as(?bool, false), dispatched.explicit_enabled);
    try std.testing.expectEqual(@as(?bool, true), dispatched.explicit_checked);
    // A route holds a command row, and a command row's children are their own
    // routes, so nothing here borrows the model's nested slice.
    try std.testing.expect(dispatched.submenu == null);
    try std.testing.expectEqual(@as(win.Dword, 3), route.position);
}
