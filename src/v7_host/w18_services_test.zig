//! Integration and contract tests for W18 desktop services:
//! dialogs, menus, open_url, preferences, and Linux portal adapters.
const std = @import("std");
const sdl_session = @import("sdl_session.zig");
const dialogs = @import("dialogs.zig");
const open_url = @import("open_url.zig");
const menus = @import("menus.zig");
const preferences = @import("preferences.zig");
const nogui = @import("nogui");
const action = nogui.action;
const Session = nogui.Session;
const WidgetTree = nogui.WidgetTree;
const WidgetId = nogui.WidgetId;

/// One SDL driver for the whole test binary, held until the process exits;
/// see sdl_session.zig.
fn startDummy() !void {
    try sdl_session.acquireForTest("dummy");
}

/// A provider that records the request and replays a scripted outcome later,
/// standing in for a native dialog that completes after other host events.
const ScriptedProvider = struct {
    last: ?dialogs.FileCallback = null,
    file_calls: usize = 0,
    message_calls: usize = 0,
    open_count: usize = 0,
    save_count: usize = 0,
    folder_count: usize = 0,
    last_allocator: ?std.mem.Allocator = null,

    fn file(
        allocator: std.mem.Allocator,
        ctx: *anyopaque,
        options: dialogs.FileOptions,
        callback: dialogs.FileCallback,
    ) anyerror!void {
        const self: *ScriptedProvider = @ptrCast(@alignCast(ctx));
        self.file_calls += 1;
        self.last_allocator = allocator;
        switch (options.mode) {
            .open_file, .open_multiple_files => self.open_count += 1,
            .save_file => self.save_count += 1,
            .open_folder => self.folder_count += 1,
        }
        self.last = callback;
    }

    fn message(
        _: std.mem.Allocator,
        ctx: *anyopaque,
        _: dialogs.MessageOptions,
        callback: dialogs.MessageCallback,
    ) anyerror!void {
        const self: *ScriptedProvider = @ptrCast(@alignCast(ctx));
        self.message_calls += 1;
        callback.callback(callback.context, .cancelled);
    }
};

const Receiver = struct {
    calls: usize = 0,
    outcome: ?dialogs.FileOutcome = null,

    fn onResult(ctx: ?*anyopaque, outcome: dialogs.FileOutcome) void {
        const self: *Receiver = @ptrCast(@alignCast(ctx.?));
        self.calls += 1;
        if (self.outcome) |*previous| dialogs.deinitFileOutcome(previous);
        self.outcome = outcome;
    }

    fn deinit(self: *Receiver) void {
        if (self.outcome) |*outcome| dialogs.deinitFileOutcome(outcome);
        self.* = undefined;
    }
};

const scripted_vtable: dialogs.DialogProvider.VTable = .{
    .showFileDialog = ScriptedProvider.file,
    .showMessageDialog = ScriptedProvider.message,
};

fn scriptedVTable() *const dialogs.DialogProvider.VTable {
    return &scripted_vtable;
}

test "api-w18 file dialogs report cancellation separately from an empty selection" {
    var manager = dialogs.DialogManager.init(std.testing.allocator);
    defer manager.deinit();

    var provider: ScriptedProvider = .{};
    manager.setProvider(.{ .context = &provider, .vtable = scriptedVTable() });

    var receiver: Receiver = .{};
    defer receiver.deinit();

    const approved: dialogs.PointOfRiskApproval = .{ .confirmed = true };
    try manager.showFile(
        .{ .mode = .open_file, .parent_window = 7 },
        approved,
        .{ .context = &receiver, .callback = Receiver.onResult },
    );
    try std.testing.expectEqual(@as(usize, 1), manager.pendingCount());

    // A user cancellation is its own outcome, never a successful empty list.
    const pending = provider.last.?;
    pending.callback(pending.context, .cancelled);
    try std.testing.expectEqual(@as(usize, 1), receiver.calls);
    try std.testing.expectEqual(dialogs.FileOutcome.cancelled, receiver.outcome.?);
    try std.testing.expectEqual(@as(usize, 0), manager.pendingCount());
}

test "api-w18 a synchronous provider callback followed by error does not release its lease twice" {
    const Provider = struct {
        fn file(
            _: std.mem.Allocator,
            _: *anyopaque,
            _: dialogs.FileOptions,
            callback: dialogs.FileCallback,
        ) anyerror!void {
            callback.callback(callback.context, .cancelled);
            return error.ProviderAfterDelivery;
        }
        fn message(
            _: std.mem.Allocator,
            _: *anyopaque,
            _: dialogs.MessageOptions,
            callback: dialogs.MessageCallback,
        ) anyerror!void {
            callback.callback(callback.context, .cancelled);
            return error.ProviderAfterDelivery;
        }
    };
    const vtable: dialogs.DialogProvider.VTable = .{
        .showFileDialog = Provider.file,
        .showMessageDialog = Provider.message,
    };
    var provider: u8 = 0;
    var manager = dialogs.DialogManager.init(std.testing.allocator);
    defer manager.deinit();
    manager.setProvider(.{ .context = &provider, .vtable = &vtable });
    var receiver: Receiver = .{};
    defer receiver.deinit();
    const approved: dialogs.PointOfRiskApproval = .{ .confirmed = true };
    try std.testing.expectError(error.ProviderAfterDelivery, manager.showFile(
        .{ .mode = .open_file },
        approved,
        .{ .context = &receiver, .callback = Receiver.onResult },
    ));
    try std.testing.expectEqual(@as(usize, 1), receiver.calls);
    try std.testing.expectEqual(@as(usize, 0), manager.pendingCount());
}

test "api-w18 selected paths are owned copies that outlive the provider buffer" {
    var manager = dialogs.DialogManager.init(std.testing.allocator);
    defer manager.deinit();

    var provider: ScriptedProvider = .{};
    manager.setProvider(.{ .context = &provider, .vtable = scriptedVTable() });

    var receiver: Receiver = .{};
    defer receiver.deinit();

    const approved: dialogs.PointOfRiskApproval = .{ .confirmed = true };
    try manager.showFile(
        .{ .mode = .open_multiple_files, .parent_window = 7 },
        approved,
        .{ .context = &receiver, .callback = Receiver.onResult },
    );
    try std.testing.expectEqual(@as(usize, 1), provider.open_count);

    // A native callback buffer that dies when the callback returns.
    var scratch = [_][*:0]const u8{ "first.zig", "second.zig" };
    const native: [2][*:0]const u8 = .{ scratch[0], scratch[1] };
    const pending = provider.last.?;
    pending.callback(pending.context, .{
        .selected = try dialogs.FileSelection.fromNativeList(
            provider.last_allocator.?,
            &native,
            0,
        ),
    });
    scratch[0] = "clobbered";

    try std.testing.expectEqual(@as(usize, 1), receiver.calls);
    switch (receiver.outcome.?) {
        .selected => |selection| {
            try std.testing.expectEqual(@as(usize, 2), selection.paths.len);
            try std.testing.expectEqualStrings("first.zig", selection.paths[0]);
            try std.testing.expectEqualStrings("second.zig", selection.paths[1]);
            try std.testing.expectEqual(@as(?usize, 0), selection.filter_index);
        },
        else => return error.ExpectedSelection,
    }
}

test "api-w18 a native callback after parent close is dropped and changes no state" {
    var manager = dialogs.DialogManager.init(std.testing.allocator);
    defer manager.deinit();

    var provider: ScriptedProvider = .{};
    manager.setProvider(.{ .context = &provider, .vtable = scriptedVTable() });

    var receiver: Receiver = .{};
    defer receiver.deinit();

    const approved: dialogs.PointOfRiskApproval = .{ .confirmed = true };
    try manager.showFile(
        .{ .mode = .save_file, .parent_window = 21 },
        approved,
        .{ .context = &receiver, .callback = Receiver.onResult },
    );
    try std.testing.expectEqual(@as(usize, 1), provider.save_count);
    try std.testing.expectEqual(@as(usize, 1), manager.pendingCount());

    manager.onWindowClosed(21);
    try std.testing.expectEqual(@as(usize, 1), receiver.calls);
    try std.testing.expectEqual(dialogs.FileOutcome.parent_closed, receiver.outcome.?);
    try std.testing.expectEqual(@as(usize, 0), manager.pendingCount());

    // The native dialog cannot be cancelled by SDL, so its completion still
    // arrives. It must be discarded, not delivered.
    const pending = provider.last.?;
    pending.callback(pending.context, .{
        .selected = try dialogs.FileSelection.fromNativeList(
            provider.last_allocator.?,
            &[_][*:0]const u8{"/tmp/late.zig"},
            null,
        ),
    });
    try std.testing.expectEqual(@as(usize, 1), receiver.calls);
    try std.testing.expectEqual(dialogs.FileOutcome.parent_closed, receiver.outcome.?);
}

test "api-w18 a native callback after teardown frees its outcome without a use after free" {
    var provider: ScriptedProvider = .{};
    var receiver: Receiver = .{};
    defer receiver.deinit();

    {
        var manager = dialogs.DialogManager.init(std.testing.allocator);
        manager.setProvider(.{ .context = &provider, .vtable = scriptedVTable() });
        try manager.showFile(
            .{ .mode = .open_file, .parent_window = 33 },
            .{ .confirmed = true },
            .{ .context = &receiver, .callback = Receiver.onResult },
        );
        try std.testing.expectEqual(@as(usize, 1), manager.pendingCount());
        manager.deinit();
    }

    // The manager is gone. The late callback must free its own outcome and
    // must not reach the receiver; the test allocator catches any leak.
    const pending = provider.last.?;
    pending.callback(pending.context, .{
        .selected = try dialogs.FileSelection.fromNativeList(
            provider.last_allocator.?,
            &[_][*:0]const u8{"/tmp/after-teardown.zig"},
            null,
        ),
    });
    try std.testing.expectEqual(@as(usize, 0), receiver.calls);
}

test "api-w18 parent close detaches callbacks before manager teardown" {
    var provider: ScriptedProvider = .{};
    var receiver: Receiver = .{};
    defer receiver.deinit();

    {
        var manager = dialogs.DialogManager.init(std.testing.allocator);
        defer manager.deinit();
        manager.setProvider(.{ .context = &provider, .vtable = scriptedVTable() });
        try manager.showFile(
            .{ .mode = .open_file, .parent_window = 33 },
            .{ .confirmed = true },
            .{ .context = &receiver, .callback = Receiver.onResult },
        );
        manager.onWindowClosed(33);
        try std.testing.expectEqual(@as(usize, 1), receiver.calls);
        try std.testing.expectEqual(dialogs.FileOutcome.parent_closed, receiver.outcome.?);
    }

    // Closing the parent removed the request before teardown visited it.
    // A late owned selection must still be freed without reaching either owner.
    const pending = provider.last.?;
    pending.callback(pending.context, .{
        .selected = try dialogs.FileSelection.fromNativeList(
            provider.last_allocator.?,
            &[_][*:0]const u8{"/tmp/after-parent-and-manager.zig"},
            null,
        ),
    });
    try std.testing.expectEqual(@as(usize, 1), receiver.calls);
    try std.testing.expectEqual(dialogs.FileOutcome.parent_closed, receiver.outcome.?);
}

test "api-w18 an unlaunched request resolves parent closed without a provider" {
    var manager = dialogs.DialogManager.init(std.testing.allocator);
    defer manager.deinit();

    var provider: ScriptedProvider = .{};
    manager.setProvider(.{ .context = &provider, .vtable = scriptedVTable() });

    var receiver: Receiver = .{};
    defer receiver.deinit();

    // A request with no parent window survives a window close.
    try manager.showFile(
        .{ .mode = .open_file, .parent_window = null },
        .{ .confirmed = true },
        .{ .context = &receiver, .callback = Receiver.onResult },
    );
    manager.onWindowClosed(99);
    try std.testing.expectEqual(@as(usize, 0), receiver.calls);
    try std.testing.expectEqual(@as(usize, 1), manager.pendingCount());

    provider.last.?.callback(provider.last.?.context, .cancelled);
    try std.testing.expectEqual(@as(usize, 1), receiver.calls);
}

test "api-w18 filters are checked before any native call" {
    var manager = dialogs.DialogManager.init(std.testing.allocator);
    defer manager.deinit();

    var provider: ScriptedProvider = .{};
    manager.setProvider(.{ .context = &provider, .vtable = scriptedVTable() });

    var receiver: Receiver = .{};
    defer receiver.deinit();

    // An extension list is what SDL's own filter takes, and a space is not an
    // extension character.
    try std.testing.expectError(error.InvalidFilter, manager.showFile(
        .{ .filters = &.{.{ .name = "Bad", .pattern = "sh;rm -rf" }} },
        .{ .confirmed = true },
        .{ .context = &receiver, .callback = Receiver.onResult },
    ));
    // A glob part with no `*` names one file, and no directory holds one, so
    // it is refused rather than sent and matched against nothing.
    try std.testing.expectError(error.InvalidFilter, manager.showFile(
        .{ .filters = &.{.{ .name = "Bad", .pattern = "txt", .match = .glob }} },
        .{ .confirmed = true },
        .{ .context = &receiver, .callback = Receiver.onResult },
    ));
    try std.testing.expectEqual(@as(usize, 0), provider.file_calls);
    try std.testing.expectEqual(@as(usize, 0), manager.pendingCount());

    // The pattern a real chooser answers is accepted and reaches the
    // provider, and an empty list still means no filter.
    try manager.showFile(
        .{ .filters = &.{.{ .name = "Text", .pattern = "*.txt", .match = .glob }} },
        .{ .confirmed = true },
        .{ .context = &receiver, .callback = Receiver.onResult },
    );
    const filtered = provider.last.?;
    try manager.showFile(
        .{ .filters = &.{} },
        .{ .confirmed = true },
        .{ .context = &receiver, .callback = Receiver.onResult },
    );
    try std.testing.expectEqual(@as(usize, 2), provider.file_calls);
    try std.testing.expectEqual(@as(usize, 2), manager.pendingCount());

    // Each lease resolves once, and both are dropped with the request.
    provider.last.?.callback(provider.last.?.context, .cancelled);
    filtered.callback(filtered.context, .cancelled);
    try std.testing.expectEqual(@as(usize, 2), receiver.calls);
    try std.testing.expectEqual(@as(usize, 0), manager.pendingCount());
}

test "api-w18 url ingress dispatches once and leaves ordinary launches alone" {
    var dispatcher = try open_url.UrlDispatcher.init(std.testing.allocator);
    defer dispatcher.deinit();

    const Record = struct {
        const Self = @This();
        url_count: usize = 0,
        // Only the first `last_len` bytes are live, so a zeroed tail is
        // enough for a handler that never ran.
        last_url: [128]u8 = [_]u8{0} ** 128,
        last_len: usize = 0,
        file_count: usize = 0,

        fn onUrl(ctx: ?*anyopaque, url: []const u8) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            self.url_count += 1;
            self.last_len = url.len;
            @memcpy(self.last_url[0..url.len], url);
        }

        fn onUserLaunch(ctx: ?*anyopaque, launch: open_url.IncomingLaunch) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            if (launch.kind == .file) self.file_count += 1;
        }
    };
    var record: Record = .{};

    try dispatcher.registerSchemeHandler("nogui", .{
        .context = &record,
        .handler = Record.onUrl,
    });
    dispatcher.setDefaultHandler(.{ .context = &record, .handler = Record.onUrl });

    var adapter: open_url.LaunchHookAdapter = .{
        .dispatcher = &dispatcher,
        .user_context = &record,
        .user_launch_fn = Record.onUserLaunch,
    };
    const host: *anyopaque = @ptrCast(&record);

    open_url.LaunchHookAdapter.onIncomingLaunch(&adapter, host, .{
        .kind = .file,
        .value = "/path/to/project/main.zig",
    });
    try std.testing.expectEqual(@as(usize, 1), record.file_count);
    try std.testing.expectEqual(@as(usize, 0), record.url_count);

    open_url.LaunchHookAdapter.onIncomingLaunch(&adapter, host, .{
        .kind = .text,
        .value = "nogui://open/file?path=demo.zig",
    });
    try std.testing.expectEqual(@as(usize, 1), record.file_count);
    try std.testing.expectEqual(@as(usize, 1), record.url_count);
    try std.testing.expectEqualStrings("nogui://open/file?path=demo.zig", record.last_url[0..record.last_len]);

    open_url.LaunchHookAdapter.onIncomingLaunch(&adapter, host, .{
        .kind = .text,
        .value = "https://github.com/janis/nogui",
    });
    try std.testing.expectEqual(@as(usize, 2), record.url_count);
    try std.testing.expectEqualStrings("https://github.com/janis/nogui", record.last_url[0..record.last_len]);
}

test "api-w18 menu bridge dynamic enablement follows focus context" {
    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;

    var registry = try action.Registry.init(std.testing.allocator, &session);
    defer registry.deinit();

    const UndoAction = action.Action(void, "edit.undo");
    const RedoAction = action.Action(void, "edit.redo");
    try registry.register(UndoAction);
    try registry.register(RedoAction);

    const EditorModel = struct {
        const Self = @This();
        can_undo: bool = true,
        can_redo: bool = false,

        fn undo(_: *Self, _: *const void, _: *Session) !void {}
        fn undoAvailable(self: *const Self, _: *Session) action.Availability {
            return if (self.can_undo) .available else .disabled;
        }

        fn redo(_: *Self, _: *const void, _: *Session) !void {}
        fn redoAvailable(self: *const Self, _: *Session) action.Availability {
            return if (self.can_redo) .available else .disabled;
        }
    };

    var initial_editor: EditorModel = .{};
    var editor_model = try session.create(EditorModel, &initial_editor);
    defer session.release(EditorModel, &editor_model) catch unreachable;

    const editor_widget: WidgetId = .{ .owner = 1, .slot = 100, .generation = 1 };
    const sidebar_widget: WidgetId = .{ .owner = 1, .slot = 200, .generation = 1 };

    _ = try registry.bind(
        UndoAction,
        EditorModel,
        EditorModel.undo,
        EditorModel.undoAvailable,
        .{ .widget = editor_widget },
        editor_model.weak(),
    );
    _ = try registry.bind(
        RedoAction,
        EditorModel,
        EditorModel.redo,
        EditorModel.redoAvailable,
        .{ .widget = editor_widget },
        editor_model.weak(),
    );

    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    try tree.nodes.append(std.testing.allocator, .{
        .id = @enumFromInt(1),
        .widget_id = sidebar_widget,
        .parent = .root,
        .kind = .{ .label = .{ .text = "sidebar" } },
    });
    try tree.nodes.append(std.testing.allocator, .{
        .id = @enumFromInt(2),
        .widget_id = editor_widget,
        .parent = .root,
        .kind = .{ .label = .{ .text = "editor" } },
    });

    var bridge = menus.MenuActionBridge.init(&registry);

    const edit_items = [_]menus.MenuItem{
        .{ .id = 1, .label = "Undo", .kind = .action, .action_name = "edit.undo" },
        .{ .id = 2, .label = "Redo", .kind = .action, .action_name = "edit.redo" },
    };
    const menu_lists = [_][]const menus.MenuItem{&edit_items};
    const menu_titles = [_]menus.Menu{.{
        .title = "Edit",
        .items = menu_lists[0],
    }};
    const menu_bar: menus.MenuBar = .{ .menus = &menu_titles };

    var eval_editor = try bridge.evaluate(std.testing.allocator, menu_bar, &tree, editor_widget);
    defer eval_editor.deinit();

    try std.testing.expect(eval_editor.menus[0].items[0].enabled);
    try std.testing.expect(!eval_editor.menus[0].items[1].enabled);

    var eval_sidebar = try bridge.evaluate(std.testing.allocator, menu_bar, &tree, sidebar_widget);
    defer eval_sidebar.deinit();

    try std.testing.expect(!eval_sidebar.menus[0].items[0].enabled);
    try std.testing.expect(!eval_sidebar.menus[0].items[1].enabled);
}

test "api-w18 menu tick marks follow the focused model and run no handler" {
    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;

    var registry = try action.Registry.init(std.testing.allocator, &session);
    defer registry.deinit();

    const BoldAction = action.Action(void, "edit.bold");
    const WrapAction = action.Action(void, "edit.wrap");
    try registry.register(BoldAction);
    try registry.register(WrapAction);

    const Editor = struct {
        const Self = @This();
        bold: bool = false,
        wrap: bool = true,
        calls: u32 = 0,

        fn toggleBold(self: *Self, _: *const void, _: *Session) !void {
            self.calls += 1;
            self.bold = !self.bold;
        }

        fn boldAvailable(_: *const Self, _: *Session) action.Availability {
            return .available;
        }

        fn boldMarked(self: *const Self, _: *Session) bool {
            return self.bold;
        }

        fn wrapAvailable(_: *const Self, _: *Session) action.Availability {
            return .disabled;
        }

        fn wrapMarked(self: *const Self, _: *Session) bool {
            return self.wrap;
        }

        fn notHere(self: *Self, _: *const void, _: *Session) !void {
            self.calls += 1;
        }
    };

    var initial_editor: Editor = .{};
    var editor = try session.create(Editor, &initial_editor);
    defer session.release(Editor, &editor) catch unreachable;

    const editor_widget: WidgetId = .{ .owner = 1, .slot = 300, .generation = 1 };
    const sidebar_widget: WidgetId = .{ .owner = 1, .slot = 301, .generation = 1 };

    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();
    try tree.nodes.append(std.testing.allocator, .{
        .id = @enumFromInt(1),
        .widget_id = editor_widget,
        .parent = .root,
        .kind = .{ .label = .{ .text = "editor" } },
    });
    try tree.nodes.append(std.testing.allocator, .{
        .id = @enumFromInt(2),
        .widget_id = sidebar_widget,
        .parent = .root,
        .kind = .{ .label = .{ .text = "sidebar" } },
    });

    const bold_token = try registry.bind(
        BoldAction,
        Editor,
        Editor.toggleBold,
        Editor.boldAvailable,
        .{ .widget = editor_widget },
        editor.weak(),
    );
    try registry.bindCheck(Editor, Editor.boldMarked, bold_token);
    const wrap_token = try registry.bind(
        WrapAction,
        Editor,
        Editor.notHere,
        Editor.wrapAvailable,
        .{ .widget = editor_widget },
        editor.weak(),
    );
    try registry.bindCheck(Editor, Editor.wrapMarked, wrap_token);

    var bridge = menus.MenuActionBridge.init(&registry);
    const items = [_]menus.MenuItem{
        .{ .id = 1, .label = "Bold", .kind = .action, .action_name = BoldAction.name },
        .{ .id = 2, .label = "Wrap", .kind = .action, .action_name = WrapAction.name },
    };
    const titles = [_]menus.Menu{.{ .title = "Format", .items = &items }};
    const menu_bar: menus.MenuBar = .{ .menus = &titles };

    var focused = try bridge.evaluate(std.testing.allocator, menu_bar, &tree, editor_widget);
    defer focused.deinit();

    try std.testing.expect(focused.menus[0].items[0].enabled);
    try std.testing.expect(!focused.menus[0].items[0].checked);
    // Disabled, yet still marked: the greyed row keeps the model's own mark.
    try std.testing.expect(!focused.menus[0].items[1].enabled);
    try std.testing.expect(focused.menus[0].items[1].checked);

    var sidebar = try bridge.evaluate(std.testing.allocator, menu_bar, &tree, sidebar_widget);
    defer sidebar.deinit();

    // A widget that owns no binding owns no mark either.
    try std.testing.expect(!sidebar.menus[0].items[0].enabled);
    try std.testing.expect(!sidebar.menus[0].items[0].checked);
    try std.testing.expect(!sidebar.menus[0].items[1].checked);

    const Untouched = struct {
        fn run(value: *const Editor, _: void) !void {
            try std.testing.expectEqual(@as(u32, 0), value.calls);
        }
    };
    try session.read(Editor, editor.weak(), {}, Untouched.run);

    // A model change with no dispatch is what the next snapshot reads.
    const Mark = struct {
        fn run(value: *Editor, _: void) !void {
            value.bold = true;
        }
    };
    try session.update(Editor, editor.weak(), {}, Mark.run);

    var marked = try bridge.evaluate(std.testing.allocator, menu_bar, &tree, editor_widget);
    defer marked.deinit();

    try std.testing.expect(marked.menus[0].items[0].checked);
    try std.testing.expect(marked.menus[0].items[1].checked);
    try session.read(Editor, editor.weak(), {}, Untouched.run);
}

test "api-w18 menu tick marks follow an alias and expire with their owner" {
    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;

    var registry = try action.Registry.init(std.testing.allocator, &session);
    defer registry.deinit();

    const DraftAction = action.Action(void, "file.draft");
    const PlainAction = action.Action(void, "file.plain");
    try registry.register(DraftAction);
    try registry.register(PlainAction);
    try registry.registerAlias("file.save-as", DraftAction.name);

    const Draft = struct {
        const Self = @This();
        marked: bool,
        sink: *u32,

        fn save(self: *Self, _: *const void, _: *Session) !void {
            self.sink.* += 1;
        }

        fn available(_: *const Self, _: *Session) action.Availability {
            return .available;
        }

        fn isMarked(self: *const Self, _: *Session) bool {
            return self.marked;
        }
    };

    var live_calls: u32 = 0;
    var retired_calls: u32 = 0;
    var live_initial: Draft = .{ .marked = true, .sink = &live_calls };
    var live = try session.create(Draft, &live_initial);
    defer session.release(Draft, &live) catch unreachable;
    var retired_initial: Draft = .{ .marked = true, .sink = &retired_calls };
    var retired = try session.create(Draft, &retired_initial);

    const draft_widget: WidgetId = .{ .owner = 1, .slot = 400, .generation = 1 };
    const retired_widget: WidgetId = .{ .owner = 1, .slot = 401, .generation = 1 };

    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();
    try tree.nodes.append(std.testing.allocator, .{
        .id = @enumFromInt(1),
        .widget_id = draft_widget,
        .parent = .root,
        .kind = .{ .label = .{ .text = "draft" } },
    });
    try tree.nodes.append(std.testing.allocator, .{
        .id = @enumFromInt(2),
        .widget_id = retired_widget,
        .parent = .root,
        .kind = .{ .label = .{ .text = "retired" } },
    });

    const live_token = try registry.bind(
        DraftAction,
        Draft,
        Draft.save,
        Draft.available,
        .{ .widget = draft_widget },
        live.weak(),
    );
    try registry.bindCheck(Draft, Draft.isMarked, live_token);
    const retired_token = try registry.bind(
        DraftAction,
        Draft,
        Draft.save,
        Draft.available,
        .{ .widget = retired_widget },
        retired.weak(),
    );
    try registry.bindCheck(Draft, Draft.isMarked, retired_token);
    try session.release(Draft, &retired);

    var bridge = menus.MenuActionBridge.init(&registry);
    const items = [_]menus.MenuItem{
        .{ .id = 1, .label = "Save as", .kind = .action, .action_name = "file.save-as" },
        .{ .id = 2, .label = "Plain", .kind = .action, .action_name = PlainAction.name },
        .{
            .id = 3,
            .label = "Minimize",
            .kind = .system_action,
            .system_action = .minimize,
            .explicit_checked = true,
        },
    };
    const titles = [_]menus.Menu{.{ .title = "File", .items = &items }};
    const menu_bar: menus.MenuBar = .{ .menus = &titles };

    var live_menu = try bridge.evaluate(std.testing.allocator, menu_bar, &tree, draft_widget);
    defer live_menu.deinit();

    // The alias reads the live owner's mark, the unbound action reads
    // nothing, and the declared mark still answers for a system action.
    try std.testing.expect(live_menu.menus[0].items[0].checked);
    try std.testing.expect(live_menu.menus[0].items[0].enabled);
    try std.testing.expect(!live_menu.menus[0].items[1].checked);
    try std.testing.expect(!live_menu.menus[0].items[1].enabled);
    try std.testing.expect(live_menu.menus[0].items[2].checked);

    var retired_menu = try bridge.evaluate(std.testing.allocator, menu_bar, &tree, retired_widget);
    defer retired_menu.deinit();

    // The retired owner still claimed a mark while it was alive. Releasing it
    // takes the claim with it.
    try std.testing.expect(!retired_menu.menus[0].items[0].checked);
    try std.testing.expect(!retired_menu.menus[0].items[0].enabled);

    try std.testing.expectEqual(
        action.Result.handled,
        try bridge.dispatchItem(items[0], &tree, draft_widget),
    );
    try std.testing.expectEqual(action.Result.unavailable, try bridge.dispatchItem(
        items[0],
        &tree,
        retired_widget,
    ));
    try std.testing.expectEqual(@as(u32, 1), live_calls);
    try std.testing.expectEqual(@as(u32, 0), retired_calls);
}

// A system action is an ordinary W10 action wearing the native ordinal, so
// the focused context decides whether its row is enabled, whether it carries a
// mark, and where a click lands. The bridge owns no handler of its own to
// answer from, so every outcome below is the registry's or the model's.
test "api-w18 a system menu row follows the focused binding for enablement, mark and dispatch" {
    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;

    var registry = try action.Registry.init(std.testing.allocator, &session);
    defer registry.deinit();

    // The name a Quit row dispatches under is the name the app registered, so
    // an app that never registered one leaves the row unavailable instead of
    // reaching a handler no registry owns.
    const QuitAction = action.Action(void, "system.quit");
    try registry.register(QuitAction);

    const Desktop = struct {
        const Self = @This();
        hidden: bool = false,
        calls: u32 = 0,

        fn quit(self: *Self, _: *const void, _: *Session) !void {
            self.calls += 1;
            self.hidden = true;
        }

        fn quitAvailable(_: *const Self, _: *Session) action.Availability {
            return .available;
        }

        fn quitMarked(self: *const Self, _: *Session) bool {
            return self.hidden;
        }
    };

    var initial_desktop: Desktop = .{};
    var desktop = try session.create(Desktop, &initial_desktop);
    defer session.release(Desktop, &desktop) catch unreachable;

    // Two contexts in one tree, and the system action belongs to the first.
    const window_widget: WidgetId = .{ .owner = 1, .slot = 500, .generation = 1 };
    const document_widget: WidgetId = .{ .owner = 1, .slot = 501, .generation = 1 };

    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();
    try tree.nodes.append(std.testing.allocator, .{
        .id = @enumFromInt(1),
        .widget_id = window_widget,
        .parent = .root,
        .kind = .{ .label = .{ .text = "window" } },
    });
    try tree.nodes.append(std.testing.allocator, .{
        .id = @enumFromInt(2),
        .widget_id = document_widget,
        .parent = .root,
        .kind = .{ .label = .{ .text = "document" } },
    });

    const quit_token = try registry.bind(
        QuitAction,
        Desktop,
        Desktop.quit,
        Desktop.quitAvailable,
        .{ .widget = window_widget },
        desktop.weak(),
    );
    try registry.bindCheck(Desktop, Desktop.quitMarked, quit_token);

    const Untouched = struct {
        fn run(value: *const Desktop, _: void) !void {
            try std.testing.expectEqual(@as(u32, 0), value.calls);
        }
    };

    var bridge = menus.MenuActionBridge.init(&registry);
    const items = [_]menus.MenuItem{
        .{ .id = 1, .label = "Quit", .kind = .system_action, .system_action = .quit },
        .{
            .id = 2,
            .label = "Hide",
            .kind = .system_action,
            .system_action = .hide,
            .explicit_enabled = true,
        },
    };
    const titles = [_]menus.Menu{.{ .title = "Application", .items = &items }};
    const menu_bar: menus.MenuBar = .{ .menus = &titles };

    var on_window = try bridge.evaluate(std.testing.allocator, menu_bar, &tree, window_widget);
    defer on_window.deinit();

    // The focused context owns a live binding, so the row is enabled, and the
    // mark it reads came from the model without running anything.
    try std.testing.expect(on_window.menus[0].items[0].enabled);
    try std.testing.expect(!on_window.menus[0].items[0].checked);
    try session.read(Desktop, desktop.weak(), {}, Untouched.run);

    var on_document = try bridge.evaluate(std.testing.allocator, menu_bar, &tree, document_widget);
    defer on_document.deinit();

    // The other context owns no binding, so the same row is blocked, claims no
    // mark, and refuses the click without reaching the model.
    try std.testing.expect(!on_document.menus[0].items[0].enabled);
    try std.testing.expect(!on_document.menus[0].items[0].checked);
    try std.testing.expectEqual(
        action.Result.unavailable,
        try bridge.dispatchItem(items[0], &tree, document_widget),
    );
    try session.read(Desktop, desktop.weak(), {}, Untouched.run);

    // An explicit override still answers over the registry, where the row
    // above has none.
    try std.testing.expect(on_document.menus[0].items[1].enabled);

    // The explicit dispatch reaches the registered binding, exactly once.
    try std.testing.expectEqual(
        action.Result.handled,
        try bridge.dispatchItem(items[0], &tree, window_widget),
    );
    const Quitted = struct {
        fn run(value: *const Desktop, _: void) !void {
            try std.testing.expectEqual(@as(u32, 1), value.calls);
            try std.testing.expect(value.hidden);
        }
    };
    try session.read(Desktop, desktop.weak(), {}, Quitted.run);

    // What that handler wrote is what the next snapshot reads, with no
    // dispatch behind it.
    var after_quit = try bridge.evaluate(std.testing.allocator, menu_bar, &tree, window_widget);
    defer after_quit.deinit();
    try std.testing.expect(after_quit.menus[0].items[0].checked);
}

/// The model row an evaluated snapshot row carries, rebuilt from that row
/// alone.
///
/// What a consumer dispatches from a snapshot it still holds. This test holds
/// one for the whole of its body, so every click below is routed from bytes
/// the snapshot owns rather than from the bar the caller assembled. Only a
/// command row is rebuilt this way; a submenu header's children belong to the
/// snapshot and never come back as model rows.
fn retainedRow(item: menus.EvaluatedItem) menus.MenuItem {
    return .{
        .id = item.id,
        .label = item.label,
        .kind = item.kind,
        .action_name = item.action_name,
        .action_payload_json = item.action_payload_json,
        .system_action = item.system_action,
        .shortcut_label = item.shortcut_label,
    };
}

// A bar is assembled from scratch, evaluated, and then thrown away, while the
// snapshot it produced goes on being read: the Windows adapter keeps one until
// its menu is destroyed, and any consumer still holding one can route a click
// from a row it kept. So the snapshot owns its text at every depth, and the
// routing it retained still lands on the model after the caller's bytes are
// gone.
test "api-w18 an evaluated menu still routes and reads after the caller's text is retired" {
    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;

    var registry = try action.Registry.init(std.testing.allocator, &session);
    defer registry.deinit();

    const SaveAs = action.Action(u32, "file.save-as");
    try registry.register(SaveAs);

    const Draft = struct {
        const Self = @This();
        calls: u32 = 0,
        /// What the last click carried. It is also the model's own mark, so a
        /// snapshot taken after a click reads it with no dispatch behind it.
        last: u32 = 0,
        /// The state this host formats its menu text from, so the titles and
        /// labels below are model state rather than constants.
        revision: u32 = 1,

        fn save(self: *Self, value: *const u32, _: *Session) !void {
            self.calls += 1;
            self.last = value.*;
        }
        fn available(_: *const Self, _: *Session) action.Availability {
            return .available;
        }
        fn isMarked(self: *const Self, _: *Session) bool {
            return self.last != 0;
        }
        fn readRevision(value: *const Self, out: *?u32) !void {
            out.* = value.revision;
        }
    };

    var initial: Draft = .{};
    var draft = try session.create(Draft, &initial);
    defer session.release(Draft, &draft) catch unreachable;

    const document: WidgetId = .{ .owner = 1, .slot = 600, .generation = 1 };
    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();
    try tree.nodes.append(std.testing.allocator, .{
        .id = @enumFromInt(1),
        .widget_id = document,
        .parent = .root,
        .kind = .{ .label = .{ .text = "document" } },
    });

    const save_token = try registry.bind(
        SaveAs,
        Draft,
        Draft.save,
        Draft.available,
        .{ .widget = document },
        draft.weak(),
    );
    try registry.bindCheck(Draft, Draft.isMarked, save_token);

    var bridge = menus.MenuActionBridge.init(&registry);

    // Every string this bar carries is formatted into one scratch buffer, the
    // way a host that rebuilds its bar every frame does it. The action name is
    // formatted there too, so the routing the snapshot keeps and the text it
    // shows come out of the same storage.
    const scratch = try std.testing.allocator.alloc(u8, 256);
    const title = try std.fmt.bufPrint(scratch[0..24], "Draft {d}", .{@as(u32, 1)});
    const label = try std.fmt.bufPrint(scratch[24..56], "Save as draft {d}", .{@as(u32, 1)});
    const shortcut = try std.fmt.bufPrint(scratch[56..88], "Ctrl+Shift+{c}", .{@as(u8, 'S')});
    const name = try std.fmt.bufPrint(scratch[88..120], "{s}", .{SaveAs.name});
    const payload = try std.fmt.bufPrint(scratch[120..136], "{d}", .{@as(u32, 41)});
    const nested_label = try std.fmt.bufPrint(scratch[136..168], "Save as copy {d}", .{@as(u32, 1)});
    const nested_payload = try std.fmt.bufPrint(scratch[168..184], "{d}", .{@as(u32, 42)});

    const nested = [_]menus.MenuItem{
        .{ .id = 11, .kind = .separator, .label = "" },
        .{
            .id = 12,
            .label = nested_label,
            .kind = .action,
            .action_name = name,
            .action_payload_json = nested_payload,
            .shortcut_label = shortcut,
        },
    };
    const items = [_]menus.MenuItem{
        .{
            .id = 1,
            .label = label,
            .kind = .action,
            .action_name = name,
            .action_payload_json = payload,
            .shortcut_label = shortcut,
        },
        .{ .id = 2, .label = "More", .kind = .submenu, .submenu = &nested },
    };
    const titles = [_]menus.Menu{.{ .title = title, .items = &items }};
    const bar: menus.MenuBar = .{ .menus = &titles };

    var first = try bridge.evaluate(std.testing.allocator, bar, &tree, document);
    defer first.deinit();

    // The host has moved on. The next frame's text lands in the same buffer, and
    // then the buffer itself is gone.
    @memset(scratch, 'x');
    std.testing.allocator.free(scratch);

    // What the snapshot shows is what it was evaluated with, at the top level
    // and inside the submenu, so a row two levels down is no more borrowed than
    // the row above it.
    try std.testing.expectEqualStrings("Draft 1", first.menus[0].title);
    try std.testing.expectEqualStrings("Save as draft 1", first.menus[0].items[0].label);
    try std.testing.expectEqualStrings("Ctrl+Shift+S", first.menus[0].items[0].shortcut_label.?);
    try std.testing.expectEqual(menus.MenuItemKind.submenu, first.menus[0].items[1].kind);
    try std.testing.expectEqual(@as(usize, 2), first.menus[0].items[1].submenu.?.len);
    try std.testing.expectEqualStrings(
        "Save as copy 1",
        first.menus[0].items[1].submenu.?[1].label,
    );
    // Nothing is marked yet, so the first snapshot answers for the model as it
    // was when the bar was evaluated.
    try std.testing.expect(!first.menus[0].items[0].checked);

    // A click is routed from a row the snapshot kept. Both rows reach the
    // model, each carrying the payload it was evaluated with, and neither
    // dispatch reaches back into storage the caller has already released.
    try std.testing.expectEqual(action.Result.handled, try bridge.dispatchItem(
        retainedRow(first.menus[0].items[0]),
        &tree,
        document,
    ));
    try std.testing.expectEqual(action.Result.handled, try bridge.dispatchItem(
        retainedRow(first.menus[0].items[1].submenu.?[1]),
        &tree,
        document,
    ));
    const Clicked = struct {
        fn run(value: *const Draft, _: void) !void {
            try std.testing.expectEqual(@as(u32, 2), value.calls);
            try std.testing.expectEqual(@as(u32, 42), value.last);
        }
    };
    try session.read(Draft, draft.weak(), {}, Clicked.run);

    // The model changed with no click behind it, so this host formats a new bar
    // for the same rows. What the new text says is read back out of the model
    // rather than written here, so the two cannot disagree.
    const Advance = struct {
        fn run(model: *Draft, _: void) !void {
            model.revision += 1;
        }
    };
    try session.update(Draft, draft.weak(), {}, Advance.run);

    var revision: ?u32 = null;
    try session.read(Draft, draft.weak(), &revision, Draft.readRevision);

    const frame = try std.testing.allocator.alloc(u8, 256);
    defer std.testing.allocator.free(frame);
    const frame_title = try std.fmt.bufPrint(frame[0..24], "Draft {d}", .{revision.?});
    const frame_label = try std.fmt.bufPrint(frame[24..56], "Save as draft {d}", .{revision.?});
    const frame_shortcut = try std.fmt.bufPrint(frame[56..88], "Ctrl+Alt+{c}", .{@as(u8, 'S')});
    const frame_name = try std.fmt.bufPrint(frame[88..120], "{s}", .{SaveAs.name});
    const frame_payload = try std.fmt.bufPrint(frame[120..136], "{d}", .{@as(u32, 43)});
    const frame_nested_label = try std.fmt.bufPrint(
        frame[136..168],
        "Save as copy {d}",
        .{revision.?},
    );

    const frame_nested = [_]menus.MenuItem{.{
        .id = 12,
        .label = frame_nested_label,
        .kind = .action,
        .action_name = frame_name,
        .action_payload_json = frame_payload,
        .shortcut_label = frame_shortcut,
    }};
    const frame_items = [_]menus.MenuItem{
        .{
            .id = 1,
            .label = frame_label,
            .kind = .action,
            .action_name = frame_name,
            .action_payload_json = frame_payload,
            .shortcut_label = frame_shortcut,
        },
        .{ .id = 2, .label = "More", .kind = .submenu, .submenu = &frame_nested },
    };
    const frame_titles = [_]menus.Menu{.{ .title = frame_title, .items = &frame_items }};
    const frame_bar: menus.MenuBar = .{ .menus = &frame_titles };

    var second = try bridge.evaluate(std.testing.allocator, frame_bar, &tree, document);
    defer second.deinit();

    // The current bar reads the current state, in its text and in its mark.
    try std.testing.expectEqualStrings("Draft 2", second.menus[0].title);
    try std.testing.expectEqualStrings("Save as draft 2", second.menus[0].items[0].label);
    try std.testing.expectEqualStrings(
        "Save as copy 2",
        second.menus[0].items[1].submenu.?[0].label,
    );
    try std.testing.expect(second.menus[0].items[0].checked);

    // The older snapshot is a snapshot and not a view. It still reads its own
    // text, and it still answers for the model as it was, while the newer one
    // sits next to it with the state of today.
    try std.testing.expectEqualStrings("Draft 1", first.menus[0].title);
    try std.testing.expectEqualStrings("Save as draft 1", first.menus[0].items[0].label);
    try std.testing.expect(!first.menus[0].items[0].checked);

    // The newer snapshot routes its own click, with its own payload, so two
    // live snapshots are two live routes rather than one shared set of bytes.
    try std.testing.expectEqual(action.Result.handled, try bridge.dispatchItem(
        retainedRow(second.menus[0].items[0]),
        &tree,
        document,
    ));
    const Reframed = struct {
        fn run(value: *const Draft, _: void) !void {
            try std.testing.expectEqual(@as(u32, 3), value.calls);
            try std.testing.expectEqual(@as(u32, 43), value.last);
        }
    };
    try session.read(Draft, draft.weak(), {}, Reframed.run);
}

// Availability may compact the bindings during a query. The decoy row has
// the opposite mark, so a stale index produces a visible wrong answer.
test "api-w18 a check query keeps the binding that decided while its callback compacts" {
    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;

    var registry = try action.Registry.init(std.testing.allocator, &session);
    defer registry.deinit();

    const OpenAction = action.Action(void, "file.open");
    const CloseAction = action.Action(void, "file.close");
    try registry.register(OpenAction);
    try registry.register(CloseAction);

    const Marker = struct {
        const Self = @This();
        marked: bool,
        /// Held only by the deciding owner, which cancels its peer from its
        /// own availability callback.
        registry: ?*action.Registry = null,
        peer: ?*action.Token = null,

        fn open(_: *Self, _: *const void, _: *Session) !void {}

        fn markedState(self: *const Self, _: *Session) bool {
            return self.marked;
        }

        fn always(_: *const Self, _: *Session) action.Availability {
            return .available;
        }

        fn cancellingPeer(self: *const Self, _: *Session) action.Availability {
            if (self.registry) |owner_registry| {
                if (self.peer) |peer| _ = owner_registry.unbind(peer);
            }
            return .available;
        }
    };

    // Row order is the array order the walk reads newest-first: the deciding
    // open row, then a closed-row decoy that answers the opposite mark.
    var open_initial: Marker = .{ .marked = true };
    var open_owner = try session.create(Marker, &open_initial);
    defer session.release(Marker, &open_owner) catch unreachable;
    var close_initial: Marker = .{ .marked = true };
    var close_owner = try session.create(Marker, &close_initial);
    defer session.release(Marker, &close_owner) catch unreachable;

    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();

    var peer_token = try registry.bind(
        OpenAction,
        Marker,
        Marker.open,
        Marker.always,
        .app,
        open_owner.weak(),
    );
    try registry.bindCheck(Marker, Marker.markedState, peer_token);

    var deciding_initial: Marker = .{
        .marked = false,
        .registry = &registry,
        .peer = &peer_token,
    };
    var deciding_owner = try session.create(Marker, &deciding_initial);
    defer session.release(Marker, &deciding_owner) catch unreachable;
    const deciding_token = try registry.bind(
        OpenAction,
        Marker,
        Marker.open,
        Marker.cancellingPeer,
        .app,
        deciding_owner.weak(),
    );
    try registry.bindCheck(Marker, Marker.markedState, deciding_token);

    const decoy_token = try registry.bind(
        CloseAction,
        Marker,
        Marker.open,
        Marker.always,
        .app,
        close_owner.weak(),
    );
    try registry.bindCheck(Marker, Marker.markedState, decoy_token);

    try std.testing.expectEqual(
        action.CheckState.unchecked,
        try registry.inspectCheck(&tree, null, OpenAction.name),
    );
    // The decoy row is the one a stale position would name, so this is what
    // proves the answer above came from the deciding row.
    try std.testing.expectEqual(
        action.CheckState.checked,
        try registry.inspectCheck(&tree, null, CloseAction.name),
    );
    // The cancel really ran, so the compaction above was not a no-op.
    try std.testing.expect(!registry.unbind(&peer_token));
}

test "api-w18 desktop preferences and auxiliary executable lookup" {
    var layout = try preferences.parseButtonLayout(
        std.testing.allocator,
        "close,appmenu:minimize,maximize",
    );
    defer layout.deinit();

    try std.testing.expectEqual(@as(usize, 2), layout.left.len);
    try std.testing.expectEqual(preferences.TitlebarButton.close, layout.left[0]);
    try std.testing.expectEqual(preferences.TitlebarButton.app_menu, layout.left[1]);
    try std.testing.expectEqual(@as(usize, 2), layout.right.len);
    try std.testing.expectEqual(preferences.TitlebarButton.minimize, layout.right[0]);
    try std.testing.expectEqual(preferences.TitlebarButton.maximize, layout.right[1]);

    preferences.setApplicationReducedMotion(.reduce);
    try std.testing.expectEqual(
        preferences.MotionPreference.reduce,
        preferences.getReducedMotion().?,
    );
    preferences.setApplicationReducedMotion(null);
    try std.testing.expect(preferences.getReducedMotion() == null);

    if (try preferences.getUserFolder(std.testing.allocator, .temp)) |temp| {
        defer std.testing.allocator.free(temp);
        try std.testing.expect(temp.len > 0);
    }

    const shell = try preferences.findAuxiliaryExecutable(std.testing.allocator, std.testing.io, "sh");
    defer if (shell) |path| std.testing.allocator.free(path);
    try std.testing.expect(shell != null);
    try std.testing.expect(std.mem.endsWith(u8, shell.?, "sh"));
}

test "api-w18 compositor info under the dummy video driver" {
    try startDummy();
    const info = preferences.getCompositorInfo();
    try std.testing.expectEqual(preferences.CompositorType.dummy, info.compositor_type);
}
