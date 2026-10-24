//! Native menu models, system actions, and the W10 action bridge.
//! Evaluates enabled/checked states dynamically following focused context.
//! Reports native global menu availability honestly without in-app fake fallbacks.
const std = @import("std");
const builtin = @import("builtin");
const nogui = @import("nogui");
const action = nogui.action;
const WidgetTree = nogui.WidgetTree;
const WidgetId = nogui.WidgetId;
const macos_native = @import("macos/native.zig");
const windows_menus = @import("windows/menus.zig");
const windows_root = @import("windows/root.zig");

pub const SystemAction = enum {
    quit,
    hide,
    hide_others,
    show_all,
    minimize,
    zoom,
    toggle_fullscreen,
    close_window,
    new_window,

    /// The W10 action this system action dispatches through. The ordinal is
    /// the row's identity on every native adapter, so one name derived from
    /// it is the only route into the registry, and a host that never
    /// registered that name leaves the row unavailable rather than reaching a
    /// handler nothing owns.
    pub fn actionName(self: SystemAction) []const u8 {
        return switch (self) {
            .quit => "system.quit",
            .hide => "system.hide",
            .hide_others => "system.hide-others",
            .show_all => "system.show-all",
            .minimize => "system.minimize",
            .zoom => "system.zoom",
            .toggle_fullscreen => "system.toggle-fullscreen",
            .close_window => "system.close-window",
            .new_window => "system.new-window",
        };
    }
};

pub const MenuItemKind = enum {
    action,
    system_action,
    submenu,
    separator,
};

pub const MenuItem = struct {
    id: u64 = 0,
    label: []const u8 = "",
    kind: MenuItemKind = .action,
    action_name: ?[]const u8 = null,
    action_payload_json: ?[]const u8 = null,
    system_action: ?SystemAction = null,
    shortcut_label: ?[]const u8 = null,
    /// Explicit override. If null, resolved dynamically via action registry `inspect` on focused context.
    explicit_enabled: ?bool = null,
    /// Declared tick mark. It answers over the registry in either direction:
    /// a caller that owns no model for this row declares its mark here, and
    /// one that does leaves it null so the focused model reports it through
    /// `inspectCheck` like every other action row.
    explicit_checked: ?bool = null,
    submenu: ?[]const MenuItem = null,
};

pub const Menu = struct {
    title: []const u8,
    items: []const MenuItem,
};

pub const MenuBar = struct {
    menus: []const Menu,
};

/// The W10 action name one item dispatches through. A system action names
/// itself, because its ordinal is the identity the native adapters carry;
/// nothing else in the item can disagree with it.
fn dispatchName(item: MenuItem) ?[]const u8 {
    return switch (item.kind) {
        .action => item.action_name,
        .system_action => if (item.system_action) |which| which.actionName() else null,
        .separator, .submenu => null,
    };
}

/// Evaluated snapshot of a menu item reflecting the active focused context.
///
/// Every slice here — label, shortcut, action name, payload and the rows of a
/// nested submenu — is owned by the `EvaluatedMenuBar` that produced it. A
/// snapshot is read long after the call that built it: the Windows adapter
/// keeps one until its menu is destroyed and replaces it only when a newer
/// evaluation arrives, while the model's own text is typically a scratch
/// buffer the caller has already rewritten or freed by then. Copying is what
/// makes a snapshot a snapshot instead of a view.
pub const EvaluatedItem = struct {
    id: u64,
    label: []const u8,
    enabled: bool,
    checked: bool,
    kind: MenuItemKind,
    action_name: ?[]const u8 = null,
    action_payload_json: ?[]const u8 = null,
    system_action: ?SystemAction = null,
    shortcut_label: ?[]const u8 = null,
    submenu: ?[]const EvaluatedItem = null,
};

pub const EvaluatedMenu = struct {
    /// Owned by the bar's arena, like every other string in the snapshot.
    title: []const u8,
    items: []const EvaluatedItem,
};

/// One evaluation of one bar, and the arena that owns all of it.
///
/// Nothing in here points back at the model it came from, so there is one
/// lifetime rule for a consumer and it is this one: a snapshot is valid until
/// `deinit`, and nothing the caller does to its own storage afterwards can
/// change what the snapshot says or where its clicks land.
///
/// The rule has an edge: no slice here outlives the arena. A consumer that
/// keeps a row, or a string from one, past `deinit` keeps bytes that are
/// already gone, so a consumer retaining rows beyond the bar's lifetime has to
/// own that text itself.
pub const EvaluatedMenuBar = struct {
    menus: []const EvaluatedMenu,
    /// The single owner of every byte these menus carry. Freeing the bar frees
    /// them together, so a nested row has no separate lifetime to manage.
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *EvaluatedMenuBar) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Take one string into the snapshot's own arena.
///
/// A bar is assembled from storage the caller is about to replace: the next
/// frame's labels, a scratch buffer released after the call, a builder's
/// temporary. The snapshot outlives all of that, so each string is copied once
/// here and never copied a second time on the way to a native adapter.
fn ownText(alloc: std.mem.Allocator, text: []const u8) ![]const u8 {
    return alloc.dupe(u8, text);
}

/// The same for one optional string. An absent field stays absent, and an
/// absent field allocates nothing.
fn ownOptionalText(alloc: std.mem.Allocator, text: ?[]const u8) !?[]const u8 {
    const present = text orelse return null;
    const owned = try ownText(alloc, present);
    return owned;
}

/// Bridge connecting declarative Menu models with W10 Action Registry and focused widget state.
pub const MenuActionBridge = struct {
    registry: *action.Registry,

    pub fn init(registry: *action.Registry) MenuActionBridge {
        return .{
            .registry = registry,
        };
    }

    /// Determine whether a menu item is enabled for the specified focused
    /// context. An action and a system action are both rows the registry
    /// answers for, so a system row is greyed for the reason the focused model
    /// gives and not because the bridge believed it eligible.
    pub fn isItemEnabled(
        self: *const MenuActionBridge,
        item: MenuItem,
        tree: *const WidgetTree,
        focus: ?nogui.WidgetId,
    ) bool {
        if (item.explicit_enabled) |override| return override;

        return switch (item.kind) {
            .separator => false,
            .submenu => if (item.submenu) |sub| sub.len > 0 else false,
            .action, .system_action => blk: {
                const act_name = dispatchName(item) orelse break :blk false;
                const availability = self.registry.inspect(tree, focus, act_name) catch break :blk false;
                break :blk availability == .available;
            },
        };
    }

    /// The tick mark an item carries for the specified focused context. An
    /// action item asks the registry, which resolves the same binding that
    /// decides enablement, so the mark follows the focused model rather than
    /// the model that happened to build the bar. A system action asks it under
    /// the name its ordinal derives, and answers identically. An action no
    /// live binding owns, and a row the registry cannot name, carry no mark.
    pub fn isItemChecked(
        self: *const MenuActionBridge,
        item: MenuItem,
        tree: *const WidgetTree,
        focus: ?nogui.WidgetId,
    ) bool {
        if (item.explicit_checked) |declared| return declared;

        const act_name = dispatchName(item) orelse return false;
        return switch (self.registry.inspectCheck(tree, focus, act_name) catch return false) {
            .checked => true,
            .unchecked, .unavailable => false,
        };
    }

    /// Dispatch a menu item through the W10 action registry with its payload.
    /// A system action reaches the same door under the name its ordinal
    /// derives, so a native menu click and an in-app click land on one binding.
    ///
    /// The row is read for the length of this call only, and it is not copied.
    /// A consumer that keeps a row past the call — the Windows route table
    /// does, until its menu is destroyed — therefore keeps the caller's own
    /// text alive itself. `evaluate` is the one place that copies.
    pub fn dispatchItem(
        self: *MenuActionBridge,
        item: MenuItem,
        tree: *const WidgetTree,
        focus: ?nogui.WidgetId,
    ) !action.Result {
        const act_name = dispatchName(item) orelse return .unavailable;
        return self.registry.dispatch(tree, focus, act_name, item.action_payload_json);
    }

    /// Evaluate the full MenuBar against the current focused context in WidgetTree.
    /// The resulting EvaluatedMenuBar contains up-to-date enabled and checked states.
    ///
    /// The snapshot owns every string it carries, at every depth: menu titles,
    /// item labels, shortcuts, action names, payloads and the rows of nested
    /// submenus are copied into the bar's arena as they are read. The caller's
    /// `menu_bar` may therefore be scratch storage that is rewritten or freed
    /// the moment this returns, and the bar still says what it said, still
    /// routes its clicks, and stays valid until `deinit`.
    pub fn evaluate(
        self: *const MenuActionBridge,
        gpa: std.mem.Allocator,
        menu_bar: MenuBar,
        tree: *const WidgetTree,
        focus: ?nogui.WidgetId,
    ) !EvaluatedMenuBar {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const alloc = arena.allocator();

        const menus = try alloc.alloc(EvaluatedMenu, menu_bar.menus.len);
        for (menu_bar.menus, 0..) |m, i| {
            menus[i] = .{
                .title = try ownText(alloc, m.title),
                .items = try self.evaluateItems(alloc, m.items, tree, focus),
            };
        }

        return .{
            .menus = menus,
            .arena = arena,
        };
    }

    /// Evaluate one level of rows into the same arena, recursively, so a
    /// submenu's rows are owned exactly like the rows above them and a
    /// snapshot is valid to any depth rather than only at its top level.
    fn evaluateItems(
        self: *const MenuActionBridge,
        alloc: std.mem.Allocator,
        items: []const MenuItem,
        tree: *const WidgetTree,
        focus: ?nogui.WidgetId,
    ) ![]const EvaluatedItem {
        const out = try alloc.alloc(EvaluatedItem, items.len);
        for (items, 0..) |item, i| {
            const enabled = self.isItemEnabled(item, tree, focus);
            const checked = self.isItemChecked(item, tree, focus);
            const sub = if (item.submenu) |s|
                try self.evaluateItems(alloc, s, tree, focus)
            else
                null;

            out[i] = .{
                .id = item.id,
                .label = try ownText(alloc, item.label),
                .enabled = enabled,
                .checked = checked,
                .kind = item.kind,
                .action_name = try ownOptionalText(alloc, item.action_name),
                .action_payload_json = try ownOptionalText(alloc, item.action_payload_json),
                .system_action = item.system_action,
                .shortcut_label = try ownOptionalText(alloc, item.shortcut_label),
                .submenu = sub,
            };
        }
        return out;
    }
};

/// Native desktop menu-bar support. Windows attaches its bar to a window.
/// Install through `macos.menus.Adapter` or `windows.menus.Adapter`; those
/// adapters own native resources and route actions through the live context.
pub fn hasNativeGlobalMenu() bool {
    return switch (builtin.target.os.tag) {
        .macos => macos_native.available,
        .windows => windows_menus.hasNativeGlobalMenu(),
        else => false,
    };
}

pub const RecentDocument = struct {
    path: []const u8,
    display_name: ?[]const u8 = null,
};

pub const JumpListTask = struct {
    title: []const u8,
    action_name: []const u8,
    description: ?[]const u8 = null,
};

pub const DockMenu = struct {
    items: []const MenuItem = &.{},
    recent_documents: []const RecentDocument = &.{},
    jump_list_tasks: []const JumpListTask = &.{},
};

/// Native Dock-menu or jump-list support. Publication can still be refused.
pub fn hasDockMenuSupport() bool {
    return switch (builtin.target.os.tag) {
        .macos => macos_native.available,
        .windows => windows_root.isApplicable(),
        else => false,
    };
}

/// Recent documents store following the FreeDesktop Desktop Bookmark Spec.
pub const RecentDocumentsManager = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayListUnmanaged([]const u8) = .empty,
    max_entries: usize = 30,

    pub fn init(allocator: std.mem.Allocator) RecentDocumentsManager {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *RecentDocumentsManager) void {
        for (self.entries.items) |e| {
            self.allocator.free(e);
        }
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn addDocument(self: *RecentDocumentsManager, path: []const u8) !void {
        // Remove existing duplicate
        for (self.entries.items, 0..) |e, i| {
            if (std.mem.eql(u8, e, path)) {
                self.allocator.free(e);
                _ = self.entries.swapRemove(i);
                break;
            }
        }

        // Prepend to front
        const copy = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(copy);
        try self.entries.insert(self.allocator, 0, copy);

        // Trim to max_entries
        while (self.entries.items.len > self.max_entries) {
            const popped = self.entries.pop();
            self.allocator.free(popped.?);
        }
    }

    pub fn list(self: *const RecentDocumentsManager) []const []const u8 {
        return self.entries.items;
    }

    pub fn clear(self: *RecentDocumentsManager) void {
        for (self.entries.items) |e| {
            self.allocator.free(e);
        }
        self.entries.clearRetainingCapacity();
    }
};

test "menu action bridge evaluates enabled state based on focused context" {
    var session = try nogui.Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;

    var registry = try action.Registry.init(std.testing.allocator, &session);
    defer registry.deinit();

    const CutAction = action.Action(void, "edit.cut");
    const PasteAction = action.Action(void, "edit.paste");
    try registry.register(CutAction);
    try registry.register(PasteAction);

    const ModelA = struct {
        const Self = @This();

        fn cut(self: *Self, _: *const void, _: *nogui.Session) !void {
            _ = self;
        }
        fn cutAvailable(self: *const Self, _: *nogui.Session) action.Availability {
            _ = self;
            return .available;
        }
    };
    var initial_a: ModelA = .{};
    var model_a = try session.create(ModelA, &initial_a);
    defer session.release(ModelA, &model_a) catch unreachable;

    const widget_child: WidgetId = .{ .owner = 1, .slot = 10, .generation = 1 };
    const widget_parent: WidgetId = .{ .owner = 1, .slot = 20, .generation = 1 };

    // Bind cut to widget_child
    _ = try registry.bind(
        CutAction,
        ModelA,
        ModelA.cut,
        ModelA.cutAvailable,
        .{ .widget = widget_child },
        model_a.weak(),
    );

    // Build widget tree
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    try tree.nodes.append(std.testing.allocator, .{
        .id = @fromBackingInt(@intCast(1)),
        .widget_id = widget_parent,
        .parent = .root,
        .kind = .{ .label = .{ .text = "parent" } },
    });
    try tree.nodes.append(std.testing.allocator, .{
        .id = @fromBackingInt(@intCast(2)),
        .widget_id = widget_child,
        .parent = @fromBackingInt(@intCast(1)),
        .kind = .{ .label = .{ .text = "child" } },
    });

    var bridge = MenuActionBridge.init(&registry);

    const menu_items = [_]MenuItem{
        .{
            .id = 1,
            .label = "Cut",
            .kind = .action,
            .action_name = "edit.cut",
        },
        .{
            .id = 2,
            .label = "Paste",
            .kind = .action,
            .action_name = "edit.paste",
        },
    };
    const menus = [_]Menu{.{
        .title = "Edit",
        .items = &menu_items,
    }};
    const menu_bar: MenuBar = .{ .menus = &menus };

    // When focus is at widget_child: Cut is available, Paste is unavailable
    var eval_child = try bridge.evaluate(std.testing.allocator, menu_bar, &tree, widget_child);
    defer eval_child.deinit();

    try std.testing.expectEqual(true, eval_child.menus[0].items[0].enabled); // Cut
    try std.testing.expectEqual(false, eval_child.menus[0].items[1].enabled); // Paste (unbound)

    // When focus is at widget_parent: Cut is unavailable (bound only to child)
    var eval_parent = try bridge.evaluate(std.testing.allocator, menu_bar, &tree, widget_parent);
    defer eval_parent.deinit();

    try std.testing.expectEqual(false, eval_parent.menus[0].items[0].enabled); // Cut unavailable at parent
    try std.testing.expectEqual(false, eval_parent.menus[0].items[1].enabled); // Paste
}

test "recent documents store adds tracks and clears" {
    var rdm = RecentDocumentsManager.init(std.testing.allocator);
    defer rdm.deinit();

    try rdm.addDocument("/home/user/doc1.txt");
    try rdm.addDocument("/home/user/doc2.txt");
    try rdm.addDocument("/home/user/doc1.txt"); // Deduplicated and promoted to front

    const docs = rdm.list();
    try std.testing.expectEqual(@as(usize, 2), docs.len);
    try std.testing.expectEqualStrings("/home/user/doc1.txt", docs[0]);
    try std.testing.expectEqualStrings("/home/user/doc2.txt", docs[1]);

    rdm.clear();
    try std.testing.expectEqual(@as(usize, 0), rdm.list().len);
}
