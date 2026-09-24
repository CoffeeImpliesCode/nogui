//! W10 configurable Todo shortcut smoke, driven through the real demo App.
//!
//! `--shortcut-smoke` attaches a real action registry and a real keymap to
//! the demo App with the real Todo root mounted. Every case below is real App
//! input: nearest eligible context, a user binding over a built-in one, a
//! disabled user binding, the chord deadline, and an unmatched chord suffix
//! replayed to the focused control exactly once. There is no demo-local key
//! switch and no second state machine — the demo only owns the lifetime of
//! the borrowed services.
//!
//! `--shortcut-layout-check=DRIVER[:WAIT_MS]` adds the opt-in SDL phase. It
//! opens one hidden window on the caller's display, attaches it so the host
//! service can read the native layout name and identifier, reads a physical
//! shortcut label from the live keymap, follows a real KEYMAP_CHANGED to a
//! new generation, rewrites the labels through the same keymap, and
//! exercises the per-window cursor policy on that same window. It never
//! touches the session's own display: point DISPLAY at an isolated X server
//! and pass that server's video driver.
const std = @import("std");
const Io = std.Io;
const nogui = @import("nogui");
const nogui_host = @import("nogui_host");
const sdl3 = @import("sdl3");
const noapi = @import("noapi");
/// The one public frame adapter the hosted arm paints through. It owns the
/// text engine, the scene lowering and the Oklab blit; the run owns the
/// device and the platform surface it presents into.
const frame_api = @import("v7_frame");
const NativeFrame = frame_api.NativeFrame;
const Application = nogui_host.Application;
const ManagedWindow = nogui_host.ManagedWindow;
const contract = nogui_host.window_contract;
const ui = @import("ui.zig");

const App = nogui.App;
const Session = nogui.Session;
const WidgetId = nogui.WidgetId;
const WidgetTree = nogui.WidgetTree;
const action = nogui.action;
const keymap = nogui.keymap;
const Clock = nogui.Clock;
const ev = nogui.event;

/// Chord timeout. The clock is injected, so the deadline is exact and the
/// whole interaction gate stays headless.
const chord_timeout_ns: u64 = 50 * std.time.ns_per_ms;

/// The demo's own shortcut context. The application context is implicit and
/// always considered last.
const todo_context: []const u8 = "todo";
const todo_contexts = [_][]const u8{todo_context};

/// Physical identities come from SDL, not from a demo key table, so the
/// headless gate and the live layout phase talk about the same key.
const scan_g: u32 = @intFromEnum(sdl3.Scancode.g);
const scan_h: u32 = @intFromEnum(sdl3.Scancode.h);
const scan_x: u32 = @intFromEnum(sdl3.Scancode.x);
const scan_space: u32 = @intFromEnum(sdl3.Scancode.space);
const scan_return: u32 = @intFromEnum(sdl3.Scancode.return_key);

const ctrl_g: keymap.Stroke = .{
    .key = .{ .physical = scan_g },
    .modifiers = .{ .control = true },
};
const plain_g: keymap.Stroke = .{ .key = .{ .physical = scan_g } };
const plain_h: keymap.Stroke = .{ .key = .{ .physical = scan_h } };
const space: keymap.Stroke = .{ .key = .{ .physical = scan_space } };
const enter: keymap.Stroke = .{ .key = .{ .physical = scan_return } };

const ToggleItem = action.Action(void, "todo.toggle_item");
const AddItem = action.Action(void, "todo.add_item");
const ResetCounter = action.Action(void, "todo.reset_counter");
const RemoveItem = action.Action(void, "todo.remove_item");

const surface: nogui.Size = .{ .width = 1400, .height = 1600 };

pub const Options = struct {
    /// The headless interaction gate. Skipped only when the caller asked for
    /// the SDL phase alone.
    interaction: bool = true,
    /// SDL video driver for the opt-in layout/cursor phase, for example
    /// "x11" or "dummy". Null leaves SDL untouched.
    video_driver: ?[]const u8 = null,
    /// The hosted arm: one real host window, real SDL key ingress, real host
    /// scheduling, and an external controller on the caller's own X server.
    /// It replaces the headless gate and the layout phase rather than
    /// running beside them — one run, one set of claims.
    native: bool = false,
    /// How long one controller step waits for its own evidence before the
    /// hosted run fails and names the step.
    step_ms: u64 = native_step_ms,
    /// Optional P6 PPM of the last presented frame. Null still counts the
    /// inked pixels; a path writes what the window actually showed.
    pixel_path: ?[]const u8 = null,
    /// How long the layout phase pumps the real SDL queue while a layout
    /// switch runs outside this process. Zero reads the layout once and
    /// reports the initial generation. Non-zero REQUIRES a real
    /// KEYMAP_CHANGED: the phase fails LayoutChangeNotObserved if the budget
    /// expires without one, because an unrequested wait that found nothing
    /// would otherwise read as a pass.
    layout_wait_ms: u31 = 0,
};

pub const Error = error{
    /// A binding was added or removed while a chord was still pending. The
    /// configuration sink has no App replay path, so that flush would drop
    /// real input instead of delivering it.
    ConfigDuringPendingChord,
    ReplayLostDuringConfig,
    ActionFiredDuringConfig,
    PendingChordLeftBehind,
    FocusTargetUnreachable,
    TodoWidgetMissing,
    TodoLabelMissing,
    CheckboxCountChanged,
    BindingRemovalFailed,
    UnexpectedTodoState,
    UnexpectedReplayState,
    NoPendingChord,
    UnexpectedDeadline,
    UnexpectedWaitMilliseconds,
    UnexpectedControllerCount,
    LineWithoutTerminator,
    BadVideoDriver,
    SdlInitFailed,
    ShortcutLabelMissing,
    /// A name or identifier that is present but empty is indistinguishable
    /// from a fabricated one, so the smoke refuses to print it.
    LayoutNameFabricated,
    LayoutIdentifierFabricated,
    /// The service tagged the layout authoritative and still had no name.
    NativeLayoutNameMissing,
    /// The observer and the service disagreed about the generation after a
    /// real layout change.
    StaleLayoutGeneration,
    /// The caller asked to watch for a layout change and the queue delivered
    /// none inside the budget. Reported with the event counts so an idle
    /// queue is distinguishable from a busy one carrying no keymap change.
    LayoutChangeNotObserved,
    RelabelFailed,
    RelabelMissing,
    WindowCreationFailed,
    CursorShapeRefused,
    UnexpectedCursorState,
    /// The hosted arm found no committed tree to read a claim against.
    NativeTreeMissing,
    /// A control the run must name carried no stable identity.
    UnstableTodoWidget,
    /// The platform gave a window that is not the surface the run asked for.
    NativeWindowIsNotTheCommittedSurface,
    /// The swapchain never settled, so no frame could be presented.
    SwapchainNeverSettled,
    /// A step's evidence never arrived inside that step's own budget.
    NativeStepTimedOut,
    /// The machine left the hold before the last step completed.
    NativeStepsIncomplete,
    /// More physical key-downs arrived in one step than the step records.
    KeyLogOverflow,
    /// A press never got its release: the run ends with a key still held.
    ReleasedKeysOutstanding,
    /// The controller sent keys the step never asked for.
    UnexpectedKeySequence,
    /// A Tab press arrived and focus did not move with it.
    FocusDidNotMove,
    /// The fallback resolved before its own deadline could expire.
    DeadlineFiredEarly,
    /// A claim the run states did not hold. The failing expectation is
    /// printed first, so the failure names itself.
    NativeStepFailed,
    /// A binding the protocol named by identity has none.
    MissingBindingId,
};

const Reporter = struct {
    io: Io,
    // SAFETY: `emit` formats into the buffer and reads back only the prefix
    // `bufPrint` returned, so no byte is read before it is written. The
    // hosted arm publishes whole protocol lines, so the headless arm's
    // one-sentence lines no longer size it.
    buffer: [4096]u8 = undefined,

    fn emit(self: *Reporter, comptime fmt: []const u8, args: anytype) !void {
        const text = try std.fmt.bufPrint(&self.buffer, fmt, args);
        if (text.len == 0 or text[text.len - 1] != '\n') return Error.LineWithoutTerminator;
        try Io.File.stdout().writeStreamingAll(self.io, text);
    }
};

/// The action owner is a Session model, so the registry holds a real weak
/// owner ticket: an expired owner is unavailable, not a dangling pointer.
const Controller = struct {
    todo: *ui.TodoApp,
    toggles: u32 = 0,
    additions: u32 = 0,
    resets: u32 = 0,
    removals: u32 = 0,

    fn toggleItem(self: *Controller, _: *const void, _: *Session) !void {
        self.toggles += 1;
        self.todo.done[0] = !self.todo.done[0];
    }

    fn addItem(self: *Controller, _: *const void, _: *Session) !void {
        self.additions += 1;
        self.todo.add();
    }

    fn removeItem(self: *Controller, _: *const void, _: *Session) !void {
        self.removals += 1;
        self.todo.remove();
    }

    fn resetCounter(self: *Controller, _: *const void, _: *Session) !void {
        self.resets += 1;
        self.todo.reset();
    }
};

const Counters = struct {
    toggles: u32 = 0,
    additions: u32 = 0,
    resets: u32 = 0,
    removals: u32 = 0,
};

const FakeClock = struct {
    now_ns: i96 = 0,

    fn readNow(raw: *anyopaque) i96 {
        const self: *FakeClock = @ptrCast(@alignCast(raw));
        return self.now_ns;
    }

    fn clock(self: *FakeClock) Clock {
        return .injected(self, readNow);
    }
};

/// The borrowed services. `App` holds only pointers into this struct, so it
/// outlives the App's deinit and is never copied.
const Services = struct {
    gpa: std.mem.Allocator,
    app: *App,
    session: *Session,
    time: FakeClock,
    registry: action.Registry,
    keymap: keymap.Keymap,
    controller: nogui.Model(Controller),
    attached: bool,
    leaked_replay: bool,
    leaked_action: bool,
    toggle_g: ?keymap.BindingId = null,
    add_gh: ?keymap.BindingId = null,
    space_enter: ?keymap.BindingId = null,

    /// The clock and the deadline belong to the arm that drives the map: the
    /// headless gate injects both, the hosted arm takes them from the real
    /// monotonic clock. `time` is only that gate's source.
    fn init(
        self: *Services,
        gpa: std.mem.Allocator,
        app: *App,
        session: *Session,
        todo: *ui.TodoApp,
        clock: Clock,
        timeout_ns: u64,
    ) !void {
        var initial: Controller = .{ .todo = todo };
        self.* = .{
            .gpa = gpa,
            .app = app,
            .session = session,
            .time = .{},
            // SAFETY: `init` assigns the registry before its first read.
            .registry = undefined,
            // SAFETY: `init` assigns the keymap before the App attaches it.
            .keymap = undefined,
            // SAFETY: `session.create` fills the ticket before it is borrowed.
            .controller = undefined,
            .attached = false,
            .leaked_replay = false,
            .leaked_action = false,
        };
        self.registry = try action.Registry.init(gpa, session);
        errdefer self.registry.deinit();
        self.keymap = try keymap.Keymap.init(gpa, clock, timeout_ns);
        errdefer self.keymap.deinit();
        self.controller = try session.create(Controller, &initial);
        // The rollback runs while the scope is already returning an error, so
        // a failed release cannot be reported as anything but what it is.
        errdefer session.release(Controller, &self.controller) catch
            @panic("todo shortcut init rollback could not release the controller");
        try self.registry.register(ToggleItem);
        try self.registry.register(AddItem);
        try self.registry.register(ResetCounter);
        try self.registry.register(RemoveItem);
        const weak = self.controller.weak();
        _ = try self.registry.bind(ToggleItem, Controller, Controller.toggleItem, null, .app, weak);
        _ = try self.registry.bind(AddItem, Controller, Controller.addItem, null, .app, weak);
        _ = try self.registry.bind(ResetCounter, Controller, Controller.resetCounter, null, .app, weak);
        _ = try self.registry.bind(RemoveItem, Controller, Controller.removeItem, null, .app, weak);
        try app.attachShortcuts(&self.keymap, &self.registry);
        self.attached = true;
    }

    fn deinit(self: *Services) !void {
        // Detach first so the App stops borrowing, but never let a failed
        // flush keep the map, the registry or the model alive.
        var failure: ?anyerror = null;
        if (self.attached) self.app.detachShortcuts() catch |err| {
            failure = err;
        };
        self.keymap.deinit();
        self.registry.deinit();
        self.session.release(Controller, &self.controller) catch
            @panic("todo shortcut services could not release the controller model");
        if (failure) |err| {
            self.* = undefined;
            return err;
        }
        self.* = undefined;
    }

    /// Adding, removing or clearing a binding flushes a pending chord, and
    /// the App owns the only replay path. Refuse to reconfigure a live chord
    /// instead of dropping it, and record the flush if one still happens.
    fn configGuard(self: *const Services) !void {
        if (self.app.nextShortcutDeadline() != null) return Error.ConfigDuringPendingChord;
    }

    fn add(self: *Services, binding: keymap.Binding) !keymap.BindingId {
        try self.configGuard();
        return self.keymap.add(binding, self.configSink());
    }

    fn remove(self: *Services, id: keymap.BindingId) !bool {
        try self.configGuard();
        return self.keymap.remove(id, self.configSink());
    }

    fn clearSource(self: *Services, source: keymap.Source) !void {
        try self.configGuard();
        self.keymap.clearSource(source, self.configSink());
    }

    fn setLabel(self: *Services, id: keymap.BindingId, text: []const u8) !void {
        try self.configGuard();
        try self.keymap.setLabel(id, text);
    }

    fn configSink(self: *Services) keymap.Sink {
        return .{ .user = self, .on_replay = onConfigReplay, .on_action = onConfigAction };
    }

    fn onConfigReplay(raw: *anyopaque, _: keymap.Replay) void {
        const self: *Services = @ptrCast(@alignCast(raw));
        self.leaked_replay = true;
    }

    fn onConfigAction(raw: *anyopaque, _: keymap.Action) void {
        const self: *Services = @ptrCast(@alignCast(raw));
        self.leaked_action = true;
    }

    fn counters(self: *Services) !Counters {
        var out: Counters = .{};
        try self.session.read(Controller, self.controller, &out, struct {
            fn read(value: *const Controller, target: *Counters) !void {
                target.* = .{
                    .toggles = value.toggles,
                    .additions = value.additions,
                    .resets = value.resets,
                    .removals = value.removals,
                };
            }
        }.read);
        return out;
    }
};

pub fn run(
    gpa: std.mem.Allocator,
    io: Io,
    app: *App,
    session: *Session,
    todo: *ui.TodoApp,
    options: Options,
) !void {
    var out: Reporter = .{ .io = io };
    // SAFETY: `init` overwrites every field before this value is read, and a
    // failed init returns before the caller touches it. Its address is taken
    // here only to be the headless gate's injected clock, and this local
    // never moves.
    var services: Services = undefined;
    try services.init(
        gpa,
        app,
        session,
        todo,
        if (options.native) Clock.monotonic(io) else services.time.clock(),
        if (options.native) native_chord_timeout_ns else chord_timeout_ns,
    );
    defer services.deinit() catch @panic("shortcut services outlived their App");

    if (options.native) {
        try runNative(gpa, io, app, todo, &services, &out, options);
        if (services.leaked_replay) return Error.ReplayLostDuringConfig;
        if (services.leaked_action) return Error.ActionFiredDuringConfig;
        return;
    }
    if (options.interaction) {
        try interaction(&out, &services, todo);
    } else {
        // Input only reaches the keymap after a frame published a tree, so a
        // standalone layout phase still needs one.
        try present(&services, 1);
    }
    if (options.video_driver) |driver| {
        try layoutPhase(&out, &services, driver, options.layout_wait_ms);
    }
    if (services.leaked_replay) return Error.ReplayLostDuringConfig;
    if (services.leaked_action) return Error.ActionFiredDuringConfig;
    try out.emit("shortcut-smoke: OK\n", .{});
}

// ── Interaction gate ────────────────────

/// The counters and the Todo state are the only observation points. A demo
/// field would have been a second state machine; the registry counters plus
/// the mounted Todo root are the real ones.
fn interaction(out: *Reporter, services: *Services, todo: *ui.TodoApp) !void {
    const app = services.app;
    try installChords(services);

    try present(services, 1);

    // 1. The nearest eligible context wins over the implicit application one.
    _ = try services.add(.{
        .sequence = &.{ctrl_g},
        .action = ToggleItem.name,
    });
    _ = try services.add(.{
        .context = todo_context,
        .sequence = &.{ctrl_g},
        .action = AddItem.name,
    });
    try app.setShortcutContexts(&todo_contexts);
    try pressCharacter(app, scan_g, .unidentified, "g", .{ .control = true });
    try expectCounters(services, .{ .additions = 1 });
    if (todo.visible_count != 3 or todo.done[0]) return Error.UnexpectedTodoState;
    try expectTodoTree(services, 2, 3, "0 of 3 done", "Counter: 0");
    try out.emit("shortcut-smoke: nearest context 'todo' fired {s} once\n", .{AddItem.name});

    // 2. Withdrawing the context falls through to the application binding.
    try app.setShortcutContexts(&.{});
    try pressCharacter(app, scan_g, .unidentified, "g", .{ .control = true });
    try expectCounters(services, .{ .additions = 1, .toggles = 1 });
    if (!todo.done[0] or todo.visible_count != 3) return Error.UnexpectedTodoState;
    try expectTodoTree(services, 3, 3, "1 of 3 done", "Counter: 0");
    try out.emit("shortcut-smoke: application context fired {s} once\n", .{ToggleItem.name});

    // 3. A user binding outranks the built-in one at equal specificity.
    _ = try services.add(.{
        .source = .user,
        .sequence = &.{ctrl_g},
        .action = ResetCounter.name,
    });
    todo.counter = 5;
    try pressCharacter(app, scan_g, .unidentified, "g", .{ .control = true });
    try expectCounters(services, .{ .additions = 1, .toggles = 1, .resets = 1 });
    if (todo.counter != 0 or todo.visible_count != 3) return Error.UnexpectedTodoState;
    try expectTodoTree(services, 4, 3, "1 of 3 done", "Counter: 0");
    try out.emit("shortcut-smoke: user binding overrode the built-in with {s}\n", .{ResetCounter.name});

    // 4. A null action disables the binding and suppresses the default.
    todo.counter = 7;
    const disabled = try services.add(.{
        .source = .user,
        .sequence = &.{ctrl_g},
        .action = null,
    });
    try pressCharacter(app, scan_g, .unidentified, "g", .{ .control = true });
    try expectCounters(services, .{ .additions = 1, .toggles = 1, .resets = 1 });
    if (todo.counter != 7 or todo.visible_count != 3) return Error.UnexpectedTodoState;
    try expectTodoTree(services, 5, 3, "1 of 3 done", "Counter: 7");
    try out.emit("shortcut-smoke: disabled user binding suppressed {s}\n", .{ResetCounter.name});

    // 5. Removing the override restores the user's own binding.
    if (!try services.remove(disabled)) return Error.BindingRemovalFailed;
    try pressCharacter(app, scan_g, .unidentified, "g", .{ .control = true });
    try expectCounters(services, .{ .additions = 1, .toggles = 1, .resets = 2 });
    if (todo.counter != 0) return Error.UnexpectedTodoState;
    try expectTodoTree(services, 6, 3, "1 of 3 done", "Counter: 0");
    try out.emit("shortcut-smoke: removing the override restored {s}\n", .{ResetCounter.name});

    // 6. A chord prefix waits for its deadline, then resolves the fallback
    //    exactly once. The deadline is real App state, not a demo timer.
    try pressCharacter(app, scan_g, .unidentified, "g", .{});
    try expectCounters(services, .{ .additions = 1, .toggles = 1, .resets = 2 });
    const expected_deadline: ?i96 = @intCast(chord_timeout_ns);
    if (app.nextShortcutDeadline() != expected_deadline) return Error.UnexpectedDeadline;
    if (app.nextShortcutWaitMilliseconds() != @as(?u31, 50))
        return Error.UnexpectedWaitMilliseconds;
    if (todo.done[0] != true or todo.counter != 0) return Error.UnexpectedTodoState;
    services.time.now_ns = @intCast(chord_timeout_ns);
    try app.tickShortcuts();
    try expectCounters(services, .{ .additions = 1, .toggles = 2, .resets = 2 });
    if (app.nextShortcutDeadline() != null) return Error.UnexpectedDeadline;
    if (todo.done[0]) return Error.UnexpectedTodoState;
    try expectTodoTree(services, 7, 3, "0 of 3 done", "Counter: 0");
    try out.emit("shortcut-smoke: chord deadline fired {s} exactly once\n", .{ToggleItem.name});

    // 7. An unmatched chord suffix replays the buffered key to the focused
    //    control once, and a second round moves the same control by one.
    const inc = app.widgetIdForKey(.root, .{ .static = "counter-inc" }) orelse
        return Error.TodoWidgetMissing;
    try focusWidget(app, inc);
    todo.counter = 4;
    try pressNamed(app, scan_space, .space);
    if (app.nextShortcutDeadline() == null) return Error.NoPendingChord;
    if (todo.counter != 4) return Error.UnexpectedReplayState;
    try pressCharacter(app, scan_x, .unidentified, "x", .{});
    if (app.nextShortcutDeadline() != null) return Error.UnexpectedDeadline;
    if (todo.counter != 5) return Error.UnexpectedReplayState;
    try expectTodoTree(services, 8, 3, "0 of 3 done", "Counter: 5");
    try pressNamed(app, scan_space, .space);
    try pressCharacter(app, scan_x, .unidentified, "x", .{});
    if (todo.counter != 6) return Error.UnexpectedReplayState;
    try expectTodoTree(services, 9, 3, "0 of 3 done", "Counter: 6");
    try out.emit("shortcut-smoke: unmatched suffix replayed space once per round\n", .{});

    // 8. The chord still matches after the replay flushed it.
    try pressNamed(app, scan_space, .space);
    try pressNamed(app, scan_return, .enter);
    try expectCounters(services, .{ .additions = 1, .toggles = 2, .resets = 3 });
    if (todo.counter != 0) return Error.UnexpectedReplayState;
    try expectTodoTree(services, 10, 3, "0 of 3 done", "Counter: 0");
    try out.emit("shortcut-smoke: chord {s} completed after a replay\n", .{ResetCounter.name});

    // 9. A completed two-key chord fires its own action once.
    try pressCharacter(app, scan_g, .unidentified, "g", .{});
    try pressCharacter(app, scan_h, .unidentified, "h", .{});
    try expectCounters(services, .{ .additions = 2, .toggles = 2, .resets = 3 });
    if (todo.visible_count != 4) return Error.UnexpectedTodoState;
    try expectTodoTree(services, 11, 4, "0 of 4 done", "Counter: 0");
    try out.emit("shortcut-smoke: chord g h fired {s} exactly once\n", .{AddItem.name});

    if (app.nextShortcutDeadline() != null) return Error.PendingChordLeftBehind;
}

fn expectCounters(services: *Services, expected: Counters) !void {
    const actual = try services.counters();
    if (!std.meta.eql(actual, expected)) return Error.UnexpectedControllerCount;
}

/// The chord set every later phase needs. "g" and "g h" share a prefix, so a
/// lone "g" must wait for its deadline; "space enter" has no single-step
/// form, so an unmatched suffix after "space" has no fallback to resolve and
/// must replay the buffered key instead.
fn installChords(services: *Services) !void {
    try services.clearSource(.user);
    try services.clearSource(.builtin);
    services.toggle_g = try services.add(.{ .sequence = &.{plain_g}, .action = ToggleItem.name });
    services.add_gh = try services.add(.{
        .sequence = &.{ plain_g, plain_h },
        .action = AddItem.name,
    });
    services.space_enter = try services.add(.{
        .sequence = &.{ space, enter },
        .action = ResetCounter.name,
    });
}

/// The first frame publishes the keys every later assertion resolves.
fn present(services: *Services, tick: u32) !void {
    const output = try services.app.frame(tick, surface);
    if (output.json) |json| services.gpa.free(json);
}

/// One key down, carrying both the physical scancode and the logical key a
/// driver would translate. Physical identity is what the bindings match, so
/// a layout change cannot move a shortcut.
fn pressKey(
    app: *App,
    code: u32,
    key: ev.Key,
    logical: ev.LogicalKey,
    modifiers: ev.Modifiers,
) !void {
    _ = try app.handle(.{ .key_down = .{
        .key = key,
        .physical = .{ .code = code },
        .logical = logical,
        .modifiers = modifiers,
    } });
}

/// A named key carries no character text, which is exactly what a driver
/// reports for space, enter and tab.
fn pressNamed(app: *App, code: u32, key: ev.Key) !void {
    try pressKey(app, code, key, .{ .named = key }, .{});
}

fn pressCharacter(
    app: *App,
    code: u32,
    key: ev.Key,
    text: []const u8,
    modifiers: ev.Modifiers,
) !void {
    try pressKey(app, code, key, .{ .character = text }, modifiers);
}

/// Tab until the committed tree reports the target focus. The loop is
/// bounded because the demo tree can change; an unreachable target is a
/// failure, not a silent skip.
fn focusWidget(app: *App, target: WidgetId) !void {
    var attempts: u8 = 0;
    while (attempts < 96) : (attempts += 1) {
        if (app.focus_manager.current) |current| {
            if (current.eql(target)) return;
        }
        _ = try app.handle(.{ .key_down = .{ .key = .tab } });
    }
    return Error.FocusTargetUnreachable;
}

/// Present one frame and read the answer off the mounted Todo root: the
/// checkbox rows it bound and the labels it drew.
fn expectTodoTree(
    services: *Services,
    tick: u32,
    checkboxes: usize,
    footer: []const u8,
    counter_label: []const u8,
) !void {
    const output = try services.app.frame(tick, surface);
    if (output.json) |json| services.gpa.free(json);
    var rows: usize = 0;
    for (output.tree.nodes.items) |node| {
        switch (node.kind) {
            .checkbox => rows += 1,
            else => {},
        }
    }
    if (rows != checkboxes) return Error.CheckboxCountChanged;
    if (!hasLabel(output.tree, footer)) return Error.TodoLabelMissing;
    if (!hasLabel(output.tree, counter_label)) return Error.TodoLabelMissing;
}

fn hasLabel(tree: *const WidgetTree, text: []const u8) bool {
    for (tree.nodes.items) |node| {
        switch (node.kind) {
            .label => |label| if (std.mem.eql(u8, label.text, text)) return true,
            else => {},
        }
    }
    return false;
}

// ── Live layout and cursor phase ────────

const LayoutObserver = struct {
    calls: usize = 0,
    generation: u64 = 0,

    fn changed(raw: *anyopaque, change: nogui_host.keyboard.Keyboard.LayoutChange) void {
        const self: *LayoutObserver = @ptrCast(@alignCast(raw));
        self.calls += 1;
        self.generation = change.generation;
    }
};

fn layoutPhase(
    out: *Reporter,
    services: *Services,
    driver: []const u8,
    wait_ms: u31,
) !void {
    // The phase can run on its own, so it installs the same chord set the
    // interaction gate uses instead of requiring that gate first.
    if (services.toggle_g == null) try installChords(services);
    var driver_z: [32]u8 = undefined;
    const driver_name = std.fmt.bufPrintSentinel(&driver_z, "{s}", .{driver}, 0) catch
        return Error.BadVideoDriver;
    try sdl3.hints.setWithPriority(.video_driver, driver_name, .override);
    sdl3.init(.{ .video = true, .events = true }) catch return Error.SdlInitFailed;
    defer sdl3.quit(.{ .video = true, .events = true });

    // The native layout read needs SDL's own display connection, and SDL only
    // publishes it on a window. The window is hidden and lives on whatever
    // display the caller named, so the probe never touches the session's own
    // screen. The cursor phase reuses this same window.
    const window = sdl3.video.Window.init("v7-shortcut-cursor", 160, 120, .{
        .hidden = true,
    }) catch return Error.WindowCreationFailed;
    defer window.deinit();

    var keyboard = nogui_host.keyboard.Keyboard.init();
    var observer: LayoutObserver = .{};
    keyboard.setOnLayoutChanged(.{
        .context = &observer,
        .callback = LayoutObserver.changed,
    });
    keyboard.attachDisplay(window);

    try reportNativeMetadata(out, driver, keyboard.layout());

    const toggle = services.toggle_g orelse return Error.RelabelMissing;
    const add_gh = services.add_gh orelse return Error.RelabelMissing;
    const space_enter = services.space_enter orelse return Error.RelabelMissing;

    const plain_label = keyboard.shortcutLabel(scan_g, .none) orelse
        return Error.ShortcutLabelMissing;
    const ctrl_label = keyboard.shortcutLabel(scan_g, .{ .left_control = true }) orelse
        return Error.ShortcutLabelMissing;
    try out.emit(
        "shortcut-layout: scancode {d} label=\"{s}\" ctrl-label=\"{s}\"\n",
        .{ scan_g, plain_label, ctrl_label },
    );
    try relabel(services, toggle, plain_label);
    try relabel(services, add_gh, plain_label);
    try relabel(
        services,
        space_enter,
        keyboard.shortcutLabel(scan_space, .none) orelse return Error.ShortcutLabelMissing,
    );

    if (wait_ms != 0) {
        // The caller asked to watch for a real layout change, so the phase
        // waits real time for the X server to deliver a real KEYMAP_CHANGED
        // while a layout switch runs outside this process.
        const step_ns: u64 = 10 * std.time.ns_per_ms;
        var waited_ns: u64 = 0;
        var polled: u32 = 0;
        while (waited_ns < @as(u64, wait_ms) * std.time.ns_per_ms) : (waited_ns += step_ns) {
            sdl3.events.pump();
            while (sdl3.events.poll()) |raw| {
                polled += 1;
                _ = keyboard.handleEvent(&raw);
            }
            if (observer.calls != 0) break;
            try Io.sleep(out.io, .fromNanoseconds(step_ns), .real);
        }
        // A wait the caller explicitly asked for and did not get is not a pass.
        // Report exactly what the queue delivered, so a failure distinguishes
        // an idle queue from a busy one that carried no keymap change, then
        // fail by name.
        try out.emit(
            "shortcut-layout: keymap-changed observed={s} callbacks={d} " ++
                "generation={d} polled={d}\n",
            .{
                if (observer.calls == 0) "no" else "yes",
                observer.calls,
                observer.generation,
                polled,
            },
        );
        if (observer.calls == 0) return Error.LayoutChangeNotObserved;
        // A layout change re-probes before it notifies, so the service and the
        // observer have to agree on the new generation, and the metadata read
        // after the pump is the authoritative one.
        const settled = keyboard.layout();
        if (settled.generation != observer.generation) return Error.StaleLayoutGeneration;
        try reportNativeMetadata(out, driver, settled);
    }

    // The physical binding is the contract. A new label must not change what
    // the key does, so the chord is replayed through the App after relabeling.
    try relabel(
        services,
        toggle,
        keyboard.shortcutLabel(scan_g, .none) orelse return Error.ShortcutLabelMissing,
    );
    const before_counters = try services.counters();
    try pressCharacter(services.app, scan_g, .unidentified, "g", .{});
    try pressCharacter(services.app, scan_h, .unidentified, "h", .{});
    const after_counters = try services.counters();
    if (after_counters.additions != before_counters.additions + 1 or
        after_counters.toggles != before_counters.toggles)
    {
        return Error.UnexpectedControllerCount;
    }
    if (services.app.nextShortcutDeadline() != null) return Error.PendingChordLeftBehind;
    try out.emit("shortcut-layout: relabeled binding still matches its physical chord\n", .{});

    try cursorPhase(out, driver, window);
}

fn relabel(services: *Services, id: keymap.BindingId, text: []const u8) !void {
    try services.setLabel(id, text);
    const stored = services.keymap.label(id) orelse return Error.RelabelMissing;
    if (!std.mem.eql(u8, stored, text)) return Error.RelabelFailed;
}

/// The native layout name and identifier are authoritative metadata the host
/// service reads from the display; this smoke never synthesizes one. The
/// status tag decides what null means: only `x11_xkb` promised an answer, so
/// only there is a null a failure. `unsupported_by_sdl` and `xkb_unavailable`
/// have no answer to give and null is the honest result. A value that IS
/// reported must be non-empty in every case, because an empty string is
/// indistinguishable from a fabricated one.
fn reportNativeMetadata(
    out: *Reporter,
    driver: []const u8,
    layout: nogui_host.keyboard.Keyboard.Layout,
) !void {
    if (layout.name) |name| {
        if (name.len == 0) return Error.LayoutNameFabricated;
    } else if (layout.status == .x11_xkb) {
        return Error.NativeLayoutNameMissing;
    }
    if (layout.identifier) |identifier| {
        if (identifier.len == 0) return Error.LayoutIdentifierFabricated;
    }
    // Both values are capped at 96 bytes by the host probe, so the whole line
    // cannot exceed roughly 310 bytes even with both fields at their cap.
    // 512 leaves headroom without cutting a value: a cut layout name would
    // still print and would diff as a change that never happened.
    var line: [512]u8 = undefined;
    try out.emit("{s}", .{try std.fmt.bufPrint(
        &line,
        "shortcut-layout: driver={s} status={s} generation={d} " ++
            "native-name=\"{s}\" native-id=\"{s}\"\n",
        .{
            driver,
            @tagName(layout.status),
            layout.generation,
            layout.name orelse "unknown",
            layout.identifier orelse "unknown",
        },
    )});
}

/// The cursor policy is per window over SDL's process-wide cursor. It reuses
/// the hidden window the layout probe already opened, and that window never
/// receives pointer focus, so SDL's global cursor state is never changed and
/// the session's own pointer is never touched.
fn cursorPhase(out: *Reporter, driver: []const u8, window: sdl3.video.Window) !void {
    var cursor = nogui_host.cursor.Cursor.init(window) catch
        return Error.WindowCreationFailed;
    defer cursor.deinit();

    if (!cursor.visible or cursor.hidden_until_move) return Error.UnexpectedCursorState;
    try cursor.setVisible(false);
    if (cursor.visible) return Error.UnexpectedCursorState;
    try cursor.setVisible(true);
    if (!cursor.visible) return Error.UnexpectedCursorState;
    try cursor.hideUntilPointerMove();
    if (!cursor.hidden_until_move or !cursor.visible) return Error.UnexpectedCursorState;
    try out.emit(
        "shortcut-layout: cursor policy hide/show/hide-until-move recorded\n",
        .{},
    );

    // A real native system cursor needs a driver that can build one. The
    // dummy driver refuses; that refusal is reported, never replaced.
    cursor.select(.pointer) catch |err| {
        if (std.mem.eql(u8, driver, "x11")) return Error.CursorShapeRefused;
        try out.emit("shortcut-layout: cursor shape refused by driver: {s}\n", .{@errorName(err)});
        return;
    };
    if (cursor.shape != .pointer) return Error.CursorShapeRefused;
    try out.emit("shortcut-layout: cursor shape pointer selected\n", .{});
}

// ── Hosted arm: one real window, real key ingress, a real controller ──

/// The toplevel the controller aims at. The host creates the window with
/// this title and the run reports the identifier the platform gave back.
pub const native_title: [:0]const u8 = "v7-shortcut-native";

/// The same mounted Todo root the headless gate measures, on a real window.
/// Every coordinate and label a step reads back comes from that window's own
/// committed frames, so this request is a size and nothing more.
const native_width: u32 = 1400;
const native_height: u32 = 1800;

/// A chord prefix waits this long for its suffix. The headless gate injects a
/// clock and presses both keys back to back, so its 50 ms deadline is exact.
/// Here the two keys of a chord leave the controller milliseconds apart, but
/// the run may still be inside the frame the previous step committed, and one
/// frame on a software Vulkan device takes hundreds of milliseconds. The
/// deadline is sized against a frame rather than against a key: a shorter one
/// would resolve the prefix before its own suffix had even been polled. The
/// run publishes this number before it waits, and the deadline step measures
/// the resolution against it.
const native_chord_timeout_ns: u64 = 2_000 * std.time.ns_per_ms;

/// How long one step waits for its own evidence before the run fails and
/// names the step it was waiting for.
pub const native_step_ms: u64 = 5_000;
/// How long a step watches a model the controller has already driven.
const native_settle_ms: u64 = 200;
/// The pause between two host steps, and so the bound on how late a chord
/// deadline can be noticed. The deadline report prints the host's own wait
/// beside the time the fallback actually took.
const native_idle_ms: u64 = 2;
/// "No earlier than its deadline" allows one poll and the millisecond the
/// platform timer rounds to.
const native_deadline_slack_ms: u64 = 15;
/// The Tab ring is walked one press at a time. This bounds the walk; it does
/// not predict how many stops the mounted scene has.
const max_tab_presses: u8 = 64;
/// Physical key-downs one step records. A step that receives more has been
/// driven by something other than the protocol, and says so by name.
const key_log_capacity = 8;

/// One key as a step expects to receive it: the physical code a binding
/// matches, or the named key the host's own translation produced, and
/// whether control was held when it arrived.
const Key = struct {
    code: u32 = 0,
    named: ev.Key = .unidentified,
    control: bool = false,
};

/// One key-down as the platform delivered it. This log is written at the
/// native edge, before the App sees anything, and nothing else writes it. A
/// key-down the platform marked as its own autorepeat is counted and not
/// logged: a held key is one press, and a press is one log entry.
const KeyRecord = struct {
    code: u32 = 0,
    named: ev.Key = .unidentified,
    control: bool = false,
};

const no_keys: [0]Key = .{};
const tab_keys = [_]Key{.{ .named = .tab }};
const ctrl_g_keys = [_]Key{.{ .code = scan_g, .control = true }};
const g_keys = [_]Key{.{ .code = scan_g }};
const g_h_keys = [_]Key{ .{ .code = scan_g }, .{ .code = scan_h } };
const space_x_keys = [_]Key{ .{ .code = scan_space }, .{ .code = scan_x } };

/// One step of the controller protocol. The name is what the run reports, so
/// a failing step names itself in its own report line.
const Step = enum {
    warmup,
    tab,
    ctx_priority,
    app_fallback,
    user_over_builtin,
    disabled_binding,
    override_removed,
    chord_pending,
    chord_deadline,
    chord_once,
    replay_round,
    chord_complete,
    done,
};

/// A block that yields a step, or nothing while it waits for its frame.
const next_step = struct {
    fn none() ?Step {
        return null;
    }

    fn of(step: Step) ?Step {
        return step;
    }
};

fn expectedKeys(step: Step) []const Key {
    return switch (step) {
        .tab => &tab_keys,
        .ctx_priority,
        .app_fallback,
        .user_over_builtin,
        .disabled_binding,
        .override_removed,
        => &ctrl_g_keys,
        .chord_pending => &g_keys,
        .chord_complete => &g_h_keys,
        .replay_round => &space_x_keys,
        .warmup,
        .chord_deadline,
        .chord_once,
        .done,
        => &no_keys,
    };
}

/// What the controller sends, in the words an X client needs.
fn keySyms(step: Step) []const u8 {
    return switch (step) {
        .tab => "Tab",
        .ctx_priority,
        .app_fallback,
        .user_over_builtin,
        .disabled_binding,
        .override_removed,
        => "ctrl+g",
        .chord_pending => "g",
        .chord_complete => "g h",
        .replay_round => "space x",
        .warmup,
        .chord_deadline,
        .chord_once,
        .done,
        => "(no key)",
    };
}

/// The claim the step proves, printed on the step's own line so a controller
/// that reads only the protocol still knows what the run is about to check.
fn stepClaim(step: Step) []const u8 {
    return switch (step) {
        .warmup => "one committed frame, then the window may be driven",
        .tab => "one Tab; the run reports the stop focus landed on",
        .ctx_priority => "ctrl+g reaches the nearest context and adds a row",
        .app_fallback => "ctrl+g falls through to the application and ticks a row",
        .user_over_builtin => "a user ctrl+g outranks the built-in one",
        .disabled_binding => "a null user binding suppresses the built-in default",
        .override_removed => "removing the override restores the user binding",
        .chord_pending => "g alone holds a chord and the host schedules its deadline",
        .chord_deadline => "nothing: the host's own clock resolves the fallback",
        .chord_once => "nothing: the fallback fired once and stays fired",
        .replay_round => "space then an unmatched x; the prefix replays exactly once",
        .chord_complete => "g then h completes the two-key chord",
        .done => "nothing: the run holds, then closes its own window",
    };
}

/// The hosted arm's binding set. It is the same registry and the same
/// mounted Todo root the headless gate uses; only the chords differ, because
/// each arm needs every action's model effect to be visible and this model
/// has one counter that saturates and a row list that clamps. Every binding
/// here is matched by the run through the model it moves, so none of their
/// identities is read back: the one binding identity the run DOES name is
/// the user override it removes mid-protocol, and that lives on the machine.
fn installNativeBindings(services: *Services) !void {
    try services.clearSource(.user);
    try services.clearSource(.builtin);
    _ = try services.add(.{ .sequence = &.{ctrl_g}, .action = ToggleItem.name });
    _ = try services.add(.{
        .context = todo_context,
        .sequence = &.{ctrl_g},
        .action = AddItem.name,
    });
    _ = try services.add(.{ .sequence = &.{plain_g}, .action = ToggleItem.name });
    _ = try services.add(.{
        .sequence = &.{ plain_g, plain_h },
        .action = RemoveItem.name,
    });
    _ = try services.add(.{
        .sequence = &.{ space, enter },
        .action = ResetCounter.name,
    });
}

/// Report the failing expectation, then fail the run. A smoke whose failure
/// is silent is indistinguishable from a smoke that passed.
fn require(
    comptime fmt: []const u8,
    condition: bool,
    out: *Reporter,
    args: anytype,
) !void {
    if (condition) return;
    try out.emit("FAIL: " ++ fmt ++ "\n", args);
    return Error.NativeStepFailed;
}

/// A stable identity that names no widget. Every identity below starts here
/// and is filled in by `publish`.
const no_widget: WidgetId = .{ .owner = 0, .slot = 0, .generation = 0 };

fn buttonNode(tree: *const WidgetTree, label: []const u8) ?nogui.FrameNodeId {
    for (tree.nodes.items) |node| {
        switch (node.kind) {
            .button => |button| if (std.mem.eql(u8, button.label, label)) return node.id,
            else => {},
        }
    }
    return null;
}

fn counterLabel(buffer: []u8, value: u32) ![]const u8 {
    return std.fmt.bufPrint(buffer, "Counter: {d}", .{value});
}

var exts_storage: [][*:0]const u8 = &.{};

fn getExts() []const [*:0]const u8 {
    return exts_storage;
}

/// The window's own device-pixel extent, read from the window the platform
/// really gave this process and never from the size that was asked for.
fn deviceExtent(sdl: *sdl3.video.Window) !noapi.Extent2D {
    const pixels = try sdl.getSizeInPixels();
    return .{ .width = @intCast(pixels[0]), .height = @intCast(pixels[1]) };
}

/// SPIR-V words, read from the repository's committed modules. The bytes stay
/// owned for as long as the adapter needs them; `shaderCreate` copies the
/// module.
const Spv = struct {
    bytes: []u8,
    words: []const u32,

    fn load(gpa: std.mem.Allocator, io: Io, path: []const u8) !Spv {
        const bytes = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
        if (bytes.len == 0 or bytes.len % @sizeOf(u32) != 0) {
            gpa.free(bytes);
            return error.ShaderModuleMalformed;
        }
        return .{ .bytes = bytes, .words = @alignCast(std.mem.bytesAsSlice(u32, bytes)) };
    }

    fn deinit(self: *Spv, gpa: std.mem.Allocator) void {
        gpa.free(self.bytes);
        self.* = undefined;
    }
};

/// The device, the surface that presents into the real window, and the one
/// public frame adapter that paints the mounted Todo scene through them.
///
/// TEARDOWN ORDER, which is why this is one value with one `deinit`: the App
/// detaches from the endpoint first, then this value goes, then the platform
/// window. The swapchain and its platform surface belong to the X11 window
/// the host destroys after this, and quitting SDL would unload the Vulkan
/// loader a live device dispatches through.
const NativeHalf = struct {
    gpu: noapi.Gpu,
    surface: noapi.Surface,
    adapter: NativeFrame,
    quad_vert: Spv,
    quad_frag: Spv,
    sort_comp: Spv,
    fullscreen_vert: Spv,
    blit_oklab: Spv,

    fn init(self: *NativeHalf, gpa: std.mem.Allocator, io: Io, sdl: *sdl3.video.Window) !void {
        self.* = .{
            // SAFETY: the GPU handle is installed below, before any use.
            .gpu = undefined,
            // SAFETY: the surface is created inside this same `init`.
            .surface = undefined,
            // SAFETY: the adapter owns the device before `init` returns.
            .adapter = undefined,
            // SAFETY: each module is compiled below, before the pipeline uses it.
            .quad_vert = undefined,
            // SAFETY: compiled below before the pipeline uses it.
            .quad_frag = undefined,
            // SAFETY: compiled below before the pipeline uses it.
            .sort_comp = undefined,
            // SAFETY: compiled below before the pipeline uses it.
            .fullscreen_vert = undefined,
            // SAFETY: compiled below before the pipeline uses it.
            .blit_oklab = undefined,
        };
        try sdl3.vulkan.loadLibrary(null);
        const get_proc_addr = try sdl3.vulkan.getVkGetInstanceProcAddr();
        const sdl_exts = try sdl3.vulkan.getInstanceExtensions();
        const exts = try gpa.dupe([*:0]const u8, sdl_exts);
        // The loader reads the extension list while the instance is built and
        // not after, so the storage is released as soon as `Gpu.init` returns.
        exts_storage = exts;
        defer {
            gpa.free(exts);
            exts_storage = &.{};
        }
        self.gpu = try noapi.Gpu.init(.{
            // Three, not two: the renderer rings its per-frame paint buffers
            // over three slots, one per in-flight frame.
            .frames_in_flight = frame_api.scene.frames_in_flight,
            .app_name = native_title,
            .validation = false,
            .loader = .{
                .get_instance_proc_addr = @ptrCast(get_proc_addr),
                .get_instance_extensions = &getExts,
            },
            .io = io,
            .allocator = gpa,
        });
        errdefer self.gpu.deinit();
        // A platform call, so it can fail; the surface is refused rather than
        // built on an unmeasured size.
        self.surface = try noapi.Surface.initSdl(
            &self.gpu,
            @ptrCast(sdl.value),
            @ptrCast(&sdl3.c.SDL_Vulkan_CreateSurface),
            .{ .extent = try deviceExtent(sdl) },
        );
        errdefer self.surface.deinit();
        self.quad_vert = try Spv.load(gpa, io, "shaders/quad_vert.spv");
        errdefer self.quad_vert.deinit(gpa);
        self.quad_frag = try Spv.load(gpa, io, "shaders/quad_frag.spv");
        errdefer self.quad_frag.deinit(gpa);
        self.sort_comp = try Spv.load(gpa, io, "shaders/sort_comp.spv");
        errdefer self.sort_comp.deinit(gpa);
        self.fullscreen_vert = try Spv.load(gpa, io, "shaders/fullscreen_vert.spv");
        errdefer self.fullscreen_vert.deinit(gpa);
        self.blit_oklab = try Spv.load(gpa, io, "shaders/blit_oklab.spv");
        errdefer self.blit_oklab.deinit(gpa);
        try self.adapter.init(.{
            .allocator = gpa,
            .gpu = &self.gpu,
            // The face every app-owned run is shaped with. One pinned face, no
            // fallback, so a measured label and a painted glyph are the same
            // measurement at any device pixel ratio.
            .fonts = &.{.{ .family = "InterVariable", .bytes = @embedFile("InterVariable.ttf") }},
            .shaders = .{
                .quad_vert = self.quad_vert.words,
                .quad_frag = self.quad_frag.words,
                .sort_comp = self.sort_comp.words,
                .fullscreen_vert = self.fullscreen_vert.words,
                .blit_oklab = self.blit_oklab.words,
            },
            .name = "v7_shortcut_native_blit_oklab",
        });
    }

    /// The App must already have detached from `adapter.gpuEndpoint()`.
    fn deinit(self: *NativeHalf, gpa: std.mem.Allocator) void {
        self.adapter.deinit();
        self.surface.deinit();
        // After the surface: the swapchain lives on this device.
        self.gpu.deinit();
        self.blit_oklab.deinit(gpa);
        self.fullscreen_vert.deinit(gpa);
        self.sort_comp.deinit(gpa);
        self.quad_frag.deinit(gpa);
        self.quad_vert.deinit(gpa);
        self.* = undefined;
    }
};

/// The hosted step machine. One value at one address: the host hooks borrow
/// it and the run's own loop drives it, so the frame callback, the event
/// callback and the protocol all name the same state.
const NativeRun = struct {
    gpa: std.mem.Allocator,
    app: *App,
    todo: *ui.TodoApp,
    services: *Services,
    application: *Application,
    handle: contract.WindowHandle,
    native: *NativeHalf,
    report: *Reporter,
    step_ms: u64,
    tick: u32 = 1,
    frames_committed: u32 = 0,
    retries: u32 = 0,
    /// True once this value owns the device, the surface and the adapter, and
    /// after that the host hook and the caller share one release.
    live: bool = false,
    /// The frame accounting, copied out before the adapter goes: the closing
    /// report outlives it.
    stats: NativeFrame.Stats = .{},
    target: noapi.Extent2D = .{ .width = 0, .height = 0 },
    retirements: u32 = 0,
    should_close: bool = false,
    inc_key: WidgetId = no_widget,
    // Native key ingress, counted at the platform edge. Nothing reads a slot
    // past `key_count`, so the constructor leaves the log uninitialised
    // rather than paying to clear a buffer this run may never fill.
    keys: [key_log_capacity]KeyRecord,
    key_count: u8 = 0,
    key_overflow: bool = false,
    downs: u32 = 0,
    repeats: u32 = 0,
    ups: u32 = 0,
    texts: u32 = 0,
    last_key_ms: u64 = 0,
    /// The user binding this run installs to disable the default, kept so the
    /// step that removes it removes exactly that one.
    disabled_binding: ?keymap.BindingId = null,
    // The step machine.
    step: Step = .warmup,
    deadline_ms: u64 = std.math.maxInt(u64),
    /// The frame count a step's own repaint has to beat, set the first time
    /// that step sees its model change. Null until then.
    await_frame_from: ?u32 = null,
    focus_at_entry: ?WidgetId = null,
    at_entry: Counters = .{},
    tab_index: u8 = 0,
    tab_origin: ?WidgetId = null,
    replay_index: u8 = 0,
    chord_entered_ms: u64 = 0,
    min_host_wait_ms: u32 = std.math.maxInt(u32),
    done_at_ms: u64 = 0,

    fn records(self: *const NativeRun) []const KeyRecord {
        return self.keys[0..self.key_count];
    }

    fn frameStats(self: *NativeRun) NativeFrame.Stats {
        return if (self.live) self.native.adapter.stats else self.stats;
    }

    fn frameTarget(self: *NativeRun) noapi.Extent2D {
        return if (self.live) self.native.adapter.targetExtent() else self.target;
    }

    /// Give the machine a budget before the first step is entered. Without
    /// it the warmup would wait forever for a frame the platform never asks
    /// for.
    fn armWarmup(self: *NativeRun) void {
        self.deadline_ms = sdl3.timer.getMillisecondsSinceInit() + self.step_ms;
    }

    /// A step that watches a model the controller has already driven gets the
    /// settle window. The deadline step gets the chord timeout plus that
    /// window, because its whole claim is that nothing resolves it earlier.
    fn budgetFor(self: *NativeRun, step: Step) u64 {
        return switch (step) {
            .chord_deadline => native_chord_timeout_ns / std.time.ns_per_ms + native_settle_ms,
            .chord_once, .done => native_settle_ms,
            else => self.step_ms,
        };
    }

    fn enter(self: *NativeRun, step: Step, now: u64) !void {
        self.step = step;
        self.key_count = 0;
        self.key_overflow = false;
        self.await_frame_from = null;
        self.focus_at_entry = self.app.focus_manager.current;
        self.at_entry = try self.services.counters();
        self.deadline_ms = now + self.budgetFor(step);
        if (step == .done) self.done_at_ms = now;
        try self.report.emit(
            "step: {s} budget_ms={d} press=\"{s}\" expect_keys={d} tab={d} round={d} " ++
                "claim=\"{s}\"\n",
            .{
                @tagName(step),
                self.deadline_ms - now,
                keySyms(step),
                expectedKeys(step).len,
                self.tab_index,
                self.replay_index,
                stepClaim(step),
            },
        );
    }

    /// One translated platform event, recorded before the App sees it. Every
    /// key the run later claims arrived here from SDL through the host's own
    /// translation, and nothing else writes this log.
    fn note(self: *NativeRun, event: nogui.Event) void {
        switch (event) {
            .key_down => |key| {
                // A key-down the platform marked as its own autorepeat is
                // counted and not logged: a held key is one press, and one
                // press is one entry in this step's key sequence.
                if (key.repeat) {
                    self.repeats += 1;
                    return;
                }
                self.downs += 1;
                if (self.key_count == key_log_capacity) {
                    self.key_overflow = true;
                    return;
                }
                self.keys[self.key_count] = .{
                    .code = if (key.physical) |physical| physical.code else 0,
                    .named = key.key,
                    .control = key.modifiers.control,
                };
                self.key_count += 1;
                self.last_key_ms = sdl3.timer.getMillisecondsSinceInit();
            },
            .key_up => self.ups += 1,
            .text_input => self.texts += 1,
            else => {},
        }
    }

    fn recordMatches(entry: KeyRecord, want: Key) bool {
        if (entry.control != want.control) return false;
        if (want.named != .unidentified) return entry.named == want.named;
        return entry.code == want.code;
    }

    /// How the keys this step received sit against the ones its protocol line
    /// named.
    const KeyFit = enum {
        /// Every named key has arrived, in order.
        complete,
        /// A prefix of them has arrived and the rest may still come.
        pending,
        /// A key arrived that this step never named, or named twice.
        foreign,
    };

    /// The physical keys this step received, against the ones its protocol
    /// line named. A key-down the step did not name may only be the modifier
    /// the NEXT expected key is held with, and only one of them: a shortcut's
    /// own modifier is real ingress too, and a second one, or anything at all
    /// before a key that carries no modifier, is a controller that sent more
    /// than the protocol asked for. Whether that modifier press carried its
    /// own flag is the platform's business and not this run's: the key it
    /// enabled is required to carry it.
    fn fitKeys(self: *const NativeRun, expected: []const Key) KeyFit {
        var index: usize = 0;
        var held_modifier = false;
        for (self.records()) |entry| {
            if (index < expected.len and recordMatches(entry, expected[index])) {
                index += 1;
                held_modifier = false;
                continue;
            }
            if (index >= expected.len) return .foreign;
            if (!expected[index].control) return .foreign;
            if (held_modifier) return .foreign;
            held_modifier = true;
        }
        return if (index == expected.len) .complete else .pending;
    }

    fn keysMatch(self: *const NativeRun, expected: []const Key) bool {
        return self.fitKeys(expected) == .complete;
    }

    /// A key this step never asked for cannot be waited out: no later key can
    /// make the step's own sequence true again. Say which key it was and stop,
    /// instead of spending the whole budget on a wait that cannot end.
    fn reportForeignKeys(self: *NativeRun) !void {
        const report = self.report;
        try report.emit(
            "foreign: step={s} press=\"{s}\" received={d} expected={d}\n",
            .{ @tagName(self.step), keySyms(self.step), self.key_count, expectedKeys(self.step).len },
        );
        for (self.records()) |entry| {
            try report.emit(
                "foreign: key scancode={d} named={s} control={}\n",
                .{ entry.code, @tagName(entry.named), entry.control },
            );
        }
    }

    /// Whether the registry moved exactly the counters this step's claim
    /// names, counting from what it held when the step began. A step that
    /// claims nothing fired therefore requires nothing to have fired.
    fn movedTo(self: *NativeRun, delta: Counters) !bool {
        const now = try self.services.counters();
        return std.meta.eql(now, .{
            .toggles = self.at_entry.toggles + delta.toggles,
            .additions = self.at_entry.additions + delta.additions,
            .resets = self.at_entry.resets + delta.resets,
            .removals = self.at_entry.removals + delta.removals,
        });
    }

    /// Both halves of a step's evidence: the keys its protocol line named, and
    /// the model change its claim names. Neither half alone completes a step.
    fn eventSeen(self: *NativeRun, expected: []const Key, delta: Counters) !bool {
        if (!self.keysMatch(expected)) return false;
        return self.movedTo(delta);
    }

    /// Whether a frame has committed SINCE this step saw its model change.
    ///
    /// The host draws on demand, and a model can change with nothing asking
    /// for a repaint: a chord the clock resolved fires its action inside the
    /// host's own frame update. So the first pump that sees the change asks
    /// for the frame that shows it and remembers the count that frame has to
    /// beat. A frame that committed for an unrelated reason — an expose, a
    /// scale change — is not that frame, and this gate refuses it.
    fn freshFrame(self: *NativeRun) !bool {
        if (self.await_frame_from) |committed| {
            if (self.frames_committed > committed) return true;
            self.invalidate();
            return false;
        }
        self.invalidate();
        self.await_frame_from = self.frames_committed;
        return false;
    }

    /// Ask for the frame that repaints the tree this event changed. Without
    /// it the window would keep showing the pre-input pixels and the run
    /// would be asserting against a stale scene.
    fn invalidate(self: *NativeRun) void {
        const managed = self.application.getWindow(self.handle) catch return;
        managed.demand.invalidateLayout();
    }

    /// The name the committed tree gives the focused control, so the
    /// controller and the report read the same word.
    fn focusName(self: *NativeRun) []const u8 {
        const focus = self.app.focus_manager.current orelse return "none";
        const tree = self.app.tree_ptr orelse return "no committed tree";
        const node = tree.frameNode(focus) orelse return "not in this frame";
        const payload = tree.nodeConst(node) orelse return "not in this frame";
        return switch (payload.kind) {
            .button => |button| button.label,
            .checkbox => |box| box.label,
            .switch_control => |toggle| toggle.label,
            .radio => |option| option.label,
            .slider => |slider| slider.label,
            .progress => |bar| bar.label,
            else => "unlabelled control",
        };
    }

    /// The replay target is the button the run walked focus to, and a chord
    /// that replays a key to whatever happens to be focused proves nothing
    /// about that button.
    fn expectIncFocus(self: *NativeRun) !void {
        const focus = self.app.focus_manager.current orelse
            return Error.FocusTargetUnreachable;
        if (!focus.eql(self.inc_key)) return Error.FocusTargetUnreachable;
    }

    /// Read the committed frame back: the checkbox rows the mounted Todo root
    /// bound, and the labels it drew from the model this step just changed.
    fn expectScene(
        self: *NativeRun,
        checkboxes: usize,
        footer: []const u8,
        counter_label: []const u8,
    ) !void {
        const tree = self.app.tree_ptr orelse return Error.NativeTreeMissing;
        var rows: usize = 0;
        for (tree.nodes.items) |node| {
            switch (node.kind) {
                .checkbox => rows += 1,
                else => {},
            }
        }
        if (rows != checkboxes) return Error.CheckboxCountChanged;
        if (!hasLabel(tree, footer)) return Error.TodoLabelMissing;
        if (!hasLabel(tree, counter_label)) return Error.TodoLabelMissing;
    }

    fn reportState(self: *NativeRun) !void {
        const counters = try self.services.counters();
        try self.report.emit(
            "state: step={s} keys={d} downs={d} ups={d} texts={d} toggles={d} additions={d} " ++
                "resets={d} removals={d} visible={d} done0={} counter={d} focus=\"{s}\" " ++
                "deadline=\"{s}\" frames={d} presented={d}\n",
            .{
                @tagName(self.step),
                self.key_count,
                self.downs,
                self.ups,
                self.texts,
                counters.toggles,
                counters.additions,
                counters.resets,
                counters.removals,
                self.todo.visible_count,
                self.todo.done[0],
                self.todo.counter,
                self.focusName(),
                if (self.app.nextShortcutDeadline() != null) "pending" else "none",
                self.frames_committed,
                self.frameStats().frames_presented,
            },
        );
    }

    /// The run's own model field, set between steps as an arrangement and
    /// named as one. No key is involved and nothing here is an observation.
    fn arrangeCounter(self: *NativeRun, value: u32, why: []const u8) !void {
        self.todo.counter = value;
        try self.report.emit("arrange: counter={d} ({s})\n", .{ value, why });
    }

    /// Read the committed tree back and publish every number the external
    /// controller needs, before this run waits for anything at all.
    fn publish(self: *NativeRun) !void {
        const tree = self.app.tree_ptr orelse return Error.NativeTreeMissing;
        const managed = try self.application.getWindow(self.handle);
        const scale = try managed.observed.pixelScale();
        const inc = buttonNode(tree, "inc") orelse return Error.TodoWidgetMissing;
        const node = tree.nodeConst(inc) orelse return Error.TodoWidgetMissing;
        self.inc_key = node.widget_id orelse return Error.UnstableTodoWidget;

        // The X11 window the platform really created, read out of SDL's own
        // property store. An X client aims at THIS identifier: SDL's own
        // window id is a handle into this process and means nothing outside
        // it. A backend that publishes none has no such identifier, and the
        // line then prints "unknown" rather than a number nobody can use.
        const x11_window: ?i64 = if (managed.native.sdl.getProperties()) |properties|
            properties.x11_window
        else |_|
            null;

        // The real keymap behind this window, so the labels below are the
        // ones a user would read on this layout rather than a table written
        // here. An unmapped key has no label and the run says so.
        var keyboard = nogui_host.keyboard.Keyboard.init();
        keyboard.attachDisplay(managed.native.sdl);
        const report = self.report;
        try report.emit(
            "protocol: title=\"{s}\" sdl_window_id={d} logical={d}x{d} pixels={d}x{d} " ++
                "scale={d:.3}x{d:.3} video_driver={s} screen_origin=({any},{any}) " ++
                "x11_window={any} client=0,0\n",
            .{
                native_title,
                managed.native.id,
                managed.observed.size.width,
                managed.observed.size.height,
                managed.observed.pixels.width,
                managed.observed.pixels.height,
                scale.x,
                scale.y,
                sdl3.video.getCurrentDriverName() orelse "<null>",
                if (managed.observed.position) |point| @as(?i32, point.x) else null,
                if (managed.observed.position) |point| @as(?i32, point.y) else null,
                x11_window,
            },
        );
        try report.emit(
            "protocol: chord_timeout_ms={d} step_budget_ms={d} settle_ms={d} poll_ms={d} " ++
                "focus_target=\"inc\"\n",
            .{
                native_chord_timeout_ns / std.time.ns_per_ms,
                self.step_ms,
                native_settle_ms,
                native_idle_ms,
            },
        );
        try self.publishKey(&keyboard, "ctrl_g", scan_g, .{ .left_control = true });
        try self.publishKey(&keyboard, "g", scan_g, .none);
        try self.publishKey(&keyboard, "h", scan_h, .none);
        try self.publishKey(&keyboard, "x", scan_x, .none);
        try self.publishKey(&keyboard, "space", scan_space, .none);
        try self.publishKey(&keyboard, "return", scan_return, .none);
        try report.emit(
            "protocol: aim at x11_window (xdotool windowfocus <x11_window>), then perform " ++
                "exactly the keys named on each step: line; press and release every key\n",
            .{},
        );
        try report.emit(
            "bindings: ctrl+g -> {s} (application) or {s} (todo), g -> {s}, g h -> {s}, " ++
                "space Return -> {s}\n",
            .{
                ToggleItem.name,
                AddItem.name,
                ToggleItem.name,
                RemoveItem.name,
                ResetCounter.name,
            },
        );
        try report.emit(
            "ready: frames={d} presented={d}; the window may be driven now\n",
            .{ self.tick - 1, self.frameStats().frames_presented },
        );
        // Best effort, and reported: a platform that will not raise the
        // window is a fact for the controller to act on, not a reason to
        // invent a focus claim.
        managed.requestFocus() catch |err| {
            try report.emit("ready: the platform refused to raise the window: {s}\n", .{@errorName(err)});
        };
    }

    fn publishKey(
        self: *NativeRun,
        keyboard: *nogui_host.keyboard.Keyboard,
        name: []const u8,
        code: u32,
        modifiers: sdl3.keycode.KeyModifier,
    ) !void {
        const label = keyboard.shortcutLabel(code, modifiers) orelse
            return Error.ShortcutLabelMissing;
        try self.report.emit("key: {s} scancode={d} label=\"{s}\"\n", .{ name, code, label });
    }

    /// One committed frame, one presented image, through the one public frame
    /// adapter. A swapchain that is out of date is retried, bounded, so a
    /// driver that never settles fails the run instead of spinning.
    fn render(self: *NativeRun) !bool {
        const managed = try self.application.getWindow(self.handle);
        const logical: nogui.geometry.WindowSize = .{
            .width = @floatFromInt(managed.observed.size.width),
            .height = @floatFromInt(managed.observed.size.height),
        };
        if (logical.width <= 0 or logical.height <= 0) return false;
        const viewport: NativeFrame.Viewport = .{
            .logical = logical,
            .device = try deviceExtent(&managed.native.sdl),
            .scale = try managed.observed.pixelScale(),
        };
        var attempts: u32 = 0;
        while (attempts < 8) : (attempts += 1) {
            // SAFETY: `beginFrame` fills it before this iteration reads it,
            // and a refused begin continues without ever reading it.
            var frame: NativeFrame.Frame = undefined;
            if (!try self.native.adapter.beginFrame(&self.native.surface, viewport, &frame)) {
                self.retries += 1;
                continue;
            }
            var recording = true;
            errdefer if (recording) self.native.adapter.cancelFrame(&frame) catch
                @panic("shortcut native surface recording cancellation failed");
            const time_ms = sdl3.timer.getMillisecondsSinceInit();
            self.app.dispatchRootFrame(time_ms);
            const out = try self.app.frameWithGpuAtTime(
                self.tick,
                time_ms,
                .{ .width = logical.width, .height = logical.height },
                &frame.gpu_frame,
            );
            defer if (out.json) |json| self.gpa.free(json);
            self.tick += 1;
            var frame_paint = try self.native.adapter.buildScene(.{}, &out);
            defer frame_paint.deinit();
            try self.native.adapter.recordScene(&self.native.surface, &frame, &out, &frame_paint);
            // `present` closes the recording itself, so the guard is dropped
            // BEFORE the call: a present that fails must propagate its own
            // error rather than reach a cancellation of a recording that is
            // gone.
            recording = false;
            try self.native.adapter.present(&self.native.surface, &frame);
            self.frames_committed += 1;
            return true;
        }
        return Error.SwapchainNeverSettled;
    }

    fn onFrame(
        context: *anyopaque,
        _: *Application,
        _: *ManagedWindow,
        _: nogui.frame_demand.FrameDemand.Work,
    ) anyerror!bool {
        const self: *NativeRun = @ptrCast(@alignCast(context));
        return self.render();
    }

    /// One routed platform event. This is the production delivery path: the
    /// host translated a REAL SDL event and this hands the translated core
    /// event to the App, exactly as the demo window's own loop does. Nothing
    /// here constructs an event.
    fn onEvent(context: *anyopaque, _: *Application, value: Application.Event) anyerror!void {
        const self: *NativeRun = @ptrCast(@alignCast(context));
        switch (value) {
            .window => |window_event| {
                if (!std.meta.eql(window_event.handle, self.handle)) return;
                const translated = window_event.translated orelse return;
                switch (translated) {
                    .close => {
                        self.should_close = true;
                        return;
                    },
                    .resize => |resize| {
                        self.invalidate();
                        _ = try self.app.handle(resize.core);
                        return;
                    },
                    .input => |event| {
                        self.note(event);
                        self.invalidate();
                        _ = try self.app.handle(event);
                        return;
                    },
                    .key_down => |key| {
                        self.note(key.core);
                        self.invalidate();
                        _ = try self.app.handle(key.core);
                        return;
                    },
                }
            },
            .drop, .display, .system_wake => {},
        }
    }

    fn onQuitRequest(_: *anyopaque, _: *Application, _: Application.QuitToken) Application.QuitDecision {
        return .approve;
    }

    /// Everything that presents INTO this window goes here, in the order the
    /// frame module requires. Idempotent: the host hook runs while the window
    /// is still alive and the caller runs the same release on the way out.
    fn releaseNative(self: *NativeRun) void {
        if (!self.live) return;
        self.live = false;
        self.stats = self.native.adapter.stats;
        self.target = self.native.adapter.targetExtent();
        // The chord is already resolved by the time the run releases the
        // device, so nothing replays here. The keymap borrow belongs to
        // `Services`, which ends it before the map itself goes.
        self.app.focus_manager.blur(self.app.focusObserver());
        self.app.detachGpu();
        self.native.deinit(self.gpa);
        self.retirements += 1;
    }

    fn onBeforeClose(context: *anyopaque, _: *ManagedWindow) void {
        const self: *NativeRun = @ptrCast(@alignCast(context));
        self.releaseNative();
    }

    /// Everything this run does between two host steps: judge the evidence
    /// that arrived while this step was the current one.
    fn pump(self: *NativeRun) !void {
        if (self.step == .done) {
            if (sdl3.timer.getMillisecondsSinceInit() - self.done_at_ms >= native_settle_ms)
                self.should_close = true;
            return;
        }
        _ = try self.advance();
    }

    /// Judge the current step against what the real host delivered since it
    /// was entered. Returns true when the step completed and the machine
    /// moved.
    ///
    /// Every branch is a MODEL fact about the demo's own state and the
    /// registry's own counters, read after the event that produced it. A step
    /// whose evidence never arrives inside its own budget fails the run with
    /// a report of what did arrive.
    fn advance(self: *NativeRun) !bool {
        const now = sdl3.timer.getMillisecondsSinceInit();
        const report = self.report;
        var label_buffer: [32]u8 = undefined;
        // A key this step never named ends the run at once. No later key can
        // make the step's own sequence true again, so waiting out the budget
        // would only hide which key the controller sent.
        if (self.key_count != 0 and self.fitKeys(expectedKeys(self.step)) == .foreign) {
            try self.reportForeignKeys();
            return Error.UnexpectedKeySequence;
        }
        const next: ?Step = switch (self.step) {
            // ONE committed frame is the whole warmup: the host draws on
            // demand, and nothing about the protocol exists before it.
            .warmup => if (self.frames_committed >= 1) blk: {
                try self.publish();
                break :blk next_step.of(.tab);
            } else null,

            .tab => if (self.keysMatch(&tab_keys)) blk: {
                const after = self.app.focus_manager.current orelse
                    return Error.FocusDidNotMove;
                if (self.focus_at_entry) |before| {
                    if (before.eql(after)) return Error.FocusDidNotMove;
                }
                self.tab_index += 1;
                if (self.tab_origin) |origin| {
                    // The ring came back to where it started without ever
                    // reaching the button the replay steps need.
                    if (after.eql(origin)) return Error.FocusTargetUnreachable;
                } else {
                    self.tab_origin = after;
                }
                try report.emit(
                    "focus: on=\"{s}\" tab_presses={d}\n",
                    .{ self.focusName(), self.tab_index },
                );
                if (after.eql(self.inc_key)) {
                    // The nearest context is this scene's own, and it is set
                    // here so the first chord the controller sends has a
                    // context to beat.
                    try self.app.setShortcutContexts(&todo_contexts);
                    break :blk next_step.of(.ctx_priority);
                }
                if (self.tab_index >= max_tab_presses) return Error.FocusTargetUnreachable;
                break :blk next_step.of(.tab);
            } else null,

            .ctx_priority => if (try self.eventSeen(&ctrl_g_keys, .{ .additions = 1 })) blk: {
                if (!try self.freshFrame()) break :blk next_step.none();
                try self.expectScene(3, "0 of 3 done", "Counter: 0");
                try require(
                    "the nearest context did not add its row: visible={d} done0={}",
                    self.todo.visible_count == 3 and !self.todo.done[0],
                    report,
                    .{ self.todo.visible_count, self.todo.done[0] },
                );
                try report.emit(
                    "case: the nearest context 'todo' fired {s}; the application one did not\n",
                    .{AddItem.name},
                );
                try self.reportState();
                // Withdraw the context so the next chord has to fall through
                // to the implicit application binding.
                try self.app.setShortcutContexts(&.{});
                break :blk next_step.of(.app_fallback);
            } else null,

            .app_fallback => if (try self.eventSeen(&ctrl_g_keys, .{ .toggles = 1 })) blk: {
                if (!try self.freshFrame()) break :blk next_step.none();
                try self.expectScene(3, "1 of 3 done", "Counter: 0");
                try require(
                    "the application binding did not tick the first row: done0={}",
                    self.todo.done[0],
                    report,
                    .{self.todo.done[0]},
                );
                try report.emit(
                    "case: the application context fired {s} once the nearest was withdrawn\n",
                    .{ToggleItem.name},
                );
                try self.reportState();
                _ = try self.services.add(.{
                    .source = .user,
                    .sequence = &.{ctrl_g},
                    .action = ResetCounter.name,
                });
                try self.arrangeCounter(5, "so a reset has something to change");
                break :blk next_step.of(.user_over_builtin);
            } else null,

            .user_over_builtin => if (try self.eventSeen(&ctrl_g_keys, .{ .resets = 1 })) blk: {
                if (!try self.freshFrame()) break :blk next_step.none();
                try self.expectScene(3, "1 of 3 done", "Counter: 0");
                try require(
                    "the user binding did not outrank the built-in one: counter={d}",
                    self.todo.counter == 0,
                    report,
                    .{self.todo.counter},
                );
                try report.emit(
                    "case: a user ctrl+g outranked the built-in one and fired {s}\n",
                    .{ResetCounter.name},
                );
                try self.reportState();
                self.disabled_binding = try self.services.add(.{
                    .source = .user,
                    .sequence = &.{ctrl_g},
                    .action = null,
                });
                try self.arrangeCounter(7, "so a suppressed binding has something to leave");
                break :blk next_step.of(.disabled_binding);
            } else null,

            .disabled_binding => if (try self.eventSeen(&ctrl_g_keys, .{})) blk: {
                if (!try self.freshFrame()) break :blk next_step.none();
                try self.expectScene(3, "1 of 3 done", "Counter: 7");
                try require(
                    "a disabled binding still changed the model: counter={d} done0={}",
                    self.todo.counter == 7 and self.todo.done[0],
                    report,
                    .{ self.todo.counter, self.todo.done[0] },
                );
                try report.emit(
                    "case: a null user binding suppressed the built-in default; nothing fired\n",
                    .{},
                );
                try self.reportState();
                // Removing the override is the run's own configuration, so it
                // happens between steps: the next step is the one that asks
                // the controller for the key again.
                const disabled = self.disabled_binding orelse return Error.MissingBindingId;
                if (!try self.services.remove(disabled)) return Error.BindingRemovalFailed;
                break :blk next_step.of(.override_removed);
            } else null,

            .override_removed => if (try self.eventSeen(&ctrl_g_keys, .{ .resets = 1 })) blk: {
                if (!try self.freshFrame()) break :blk next_step.none();
                try self.expectScene(3, "1 of 3 done", "Counter: 0");
                try require(
                    "removing the override did not restore the user binding: counter={d}",
                    self.todo.counter == 0,
                    report,
                    .{self.todo.counter},
                );
                try report.emit(
                    "case: removing the override restored {s}; the built-in default is back\n",
                    .{ResetCounter.name},
                );
                try self.reportState();
                break :blk next_step.of(.chord_pending);
            } else null,

            .chord_pending => if (try self.eventSeen(&g_keys, .{})) blk: {
                if (self.app.nextShortcutDeadline() == null) return Error.NoPendingChord;
                // Measured from the key-down the platform delivered, not from
                // the moment this step noticed it.
                self.chord_entered_ms = self.last_key_ms;
                try report.emit(
                    "chord: prefix held, deadline_wait_ms={any} chord_timeout_ms={d}\n",
                    .{
                        self.app.nextShortcutWaitMilliseconds(),
                        native_chord_timeout_ns / std.time.ns_per_ms,
                    },
                );
                try self.reportState();
                break :blk next_step.of(.chord_deadline);
            } else null,

            // Nothing arrives here. The host's own `tickShortcuts`, called from
            // its frame update on a schedule this run never drives, is what
            // resolves the prefix.
            .chord_deadline => if (try self.eventSeen(&no_keys, .{ .toggles = 1 })) blk: {
                const elapsed = now - self.chord_entered_ms;
                const timeout_ms = native_chord_timeout_ns / std.time.ns_per_ms;
                if (elapsed + native_deadline_slack_ms < timeout_ms) return Error.DeadlineFiredEarly;
                try require(
                    "the deadline left a chord behind: wait_ms={any}",
                    self.app.nextShortcutDeadline() == null,
                    report,
                    .{self.app.nextShortcutWaitMilliseconds()},
                );
                try require(
                    "the fallback ticked the row back: done0={}",
                    !self.todo.done[0],
                    report,
                    .{self.todo.done[0]},
                );
                if (!try self.freshFrame()) break :blk next_step.none();
                try self.expectScene(3, "0 of 3 done", "Counter: 0");
                try report.emit(
                    "deadline: fired_after_ms={d} timeout_ms={d} host_wait_ms={d} keys=0\n",
                    .{ elapsed, timeout_ms, self.min_host_wait_ms },
                );
                try report.emit(
                    "case: the host's own clock resolved the prefix with {s} exactly once\n",
                    .{ToggleItem.name},
                );
                try self.reportState();
                break :blk next_step.of(.chord_once);
            } else null,

            // The "exactly once" half: nothing is pressed, so a second firing
            // could only come from that same clock a second time.
            .chord_once => if (try self.eventSeen(&no_keys, .{}) and
                now >= self.deadline_ms)
            blk: {
                try report.emit(
                    "case: still {d} toggles after {d} ms of no input; the fallback did not fire again\n",
                    .{
                        (try self.services.counters()).toggles,
                        now - (self.deadline_ms - native_settle_ms),
                    },
                );
                try self.reportState();
                // The replay target has to still hold focus, and the counter
                // needs a value the replayed prefix can move. Both are
                // arranged between steps, before the next one is announced.
                try self.expectIncFocus();
                try self.arrangeCounter(4, "so the replayed prefix has something to move");
                break :blk next_step.of(.replay_round);
            } else null,

            .replay_round => if (try self.eventSeen(&space_x_keys, .{})) blk: {
                const before: u32 = 4 + self.replay_index;
                try require(
                    "the replayed prefix moved the counter to {d}, expected exactly {d}",
                    self.todo.counter == before + 1,
                    report,
                    .{ self.todo.counter, before + 1 },
                );
                try require(
                    "the unmatched suffix left a chord behind: wait_ms={any}",
                    self.app.nextShortcutDeadline() == null,
                    report,
                    .{self.app.nextShortcutWaitMilliseconds()},
                );
                if (!try self.freshFrame()) break :blk next_step.none();
                try self.expectScene(3, "0 of 3 done", try counterLabel(&label_buffer, before + 1));
                try report.emit(
                    "case: an unmatched suffix replayed the prefix exactly once: counter {d} -> {d}\n",
                    .{ before, self.todo.counter },
                );
                try self.reportState();
                self.replay_index += 1;
                if (self.replay_index >= 2) {
                    // Both rounds moved the counter by exactly one each: a
                    // prefix replayed twice per round would have moved it by
                    // two, and the run fails on the round that shows it.
                    break :blk next_step.of(.chord_complete);
                }
                // The next round starts from the value this one left, so a
                // second replay has something of its own to move.
                try self.arrangeCounter(4 + @as(u32, self.replay_index), "the next round's base");
                break :blk next_step.of(.replay_round);
            } else null,

            .chord_complete => if (try self.eventSeen(&g_h_keys, .{ .removals = 1 })) blk: {
                try require(
                    "the two-key chord did not drop a row: visible={d}",
                    self.todo.visible_count == 2,
                    report,
                    .{self.todo.visible_count},
                );
                if (!try self.freshFrame()) break :blk next_step.none();
                try self.expectScene(2, "0 of 2 done", try counterLabel(&label_buffer, self.todo.counter));
                try report.emit(
                    "case: a completed two-key chord fired {s} exactly once\n",
                    .{RemoveItem.name},
                );
                try self.reportState();
                break :blk next_step.of(.done);
            } else null,

            .done => return false,
        };

        if (next) |step| try self.enter(step, now);
        if (next == null and now >= self.deadline_ms) {
            try self.reportTimeout(now);
            return Error.NativeStepTimedOut;
        }
        return next != null;
    }

    /// Why a step never completed: what the platform delivered, what the
    /// registry counted, and what the model held. A timeout that does not say
    /// these is indistinguishable from a controller that never ran.
    fn reportTimeout(self: *NativeRun, now: u64) !void {
        const report = self.report;
        const counters = try self.services.counters();
        const budget = self.budgetFor(self.step);
        try report.emit(
            "timeout: step={s} waited_ms={d} budget_ms={d} frames={d} presented={d} keys={d}\n",
            .{
                @tagName(self.step),
                now - (self.deadline_ms - budget),
                budget,
                self.frames_committed,
                self.frameStats().frames_presented,
                self.key_count,
            },
        );
        try report.emit(
            "timeout: model toggles={d} additions={d} resets={d} removals={d} visible={d} " ++
                "done0={} counter={d} focus=\"{s}\" deadline=\"{s}\"\n",
            .{
                counters.toggles,
                counters.additions,
                counters.resets,
                counters.removals,
                self.todo.visible_count,
                self.todo.done[0],
                self.todo.counter,
                self.focusName(),
                if (self.app.nextShortcutDeadline() != null) "pending" else "none",
            },
        );
        try report.emit(
            "timeout: totals downs={d} ups={d} repeats={d} texts={d} overflow={}\n",
            .{ self.downs, self.ups, self.repeats, self.texts, self.key_overflow },
        );
        for (self.records()) |entry| {
            try report.emit(
                "timeout: key scancode={d} named={s} control={}\n",
                .{ entry.code, @tagName(entry.named), entry.control },
            );
        }
    }
};

// ── The hosted run ──────────────────

/// Open the real host window on the caller's own display server, paint the
/// mounted Todo root through the public frame adapter, and then wait — one
/// step at a time, each with its own budget — for an external controller to
/// drive real key input at it. Nothing in this function creates an SDL event.
fn runNative(
    gpa: std.mem.Allocator,
    io: Io,
    app: *App,
    todo: *ui.TodoApp,
    services: *Services,
    out: *Reporter,
    options: Options,
) !void {
    const application = try gpa.create(Application);
    // Only the allocation is owned before `init` returns. `gpa.destroy` reads
    // nothing, so it is safe over a struct no constructor ever filled, and a
    // plain `defer` means the success path releases through the same two steps
    // an error path does.
    defer gpa.destroy(application);
    application.* = try Application.init(gpa, services.session, .{
        .app_id = "dev.nogui.shortcutnative",
        .restart = .never,
    });
    defer application.deinit();

    const handle = try application.openWindowWithApp(app, .{
        .title = native_title,
        .width = native_width,
        .height = native_height,
        // Undecorated, so a window-relative coordinate and a client-area
        // coordinate are the same number. No position is REQUESTED: a backend
        // without a global desktop space refuses one, and the run publishes
        // where the platform really put the window instead of insisting.
        .decorated = false,
        .resizable = false,
        .visible = true,
        .gpu_surface = true,
    });
    const managed = try application.getWindow(handle);
    if (managed.observed.size.width != native_width or
        managed.observed.size.height != native_height)
    {
        return Error.NativeWindowIsNotTheCommittedSurface;
    }

    // The device, the surface and the public frame adapter. The window is
    // open first because the surface is created over the window the platform
    // really gave this process.
    // SAFETY: `init` fills the whole struct, and the release below reads it
    // only when `native_live` says that call returned.
    var native: NativeHalf = undefined;
    var native_live = false;
    defer if (native_live) native.deinit(gpa);
    try native.init(gpa, io, &managed.native.sdl);
    native_live = true;

    // The App measures its layout through the engine that rasterizes the
    // glyphs and paints through the endpoint the demo's own components bind,
    // so the committed tree, the painted scene and the text metrics name one
    // set of objects.
    app.measure = native.adapter.measurer();
    try app.attachGpu(native.adapter.gpuEndpoint());
    var gpu_attached = true;
    defer if (gpu_attached) app.detachGpu();
    todo.setGpuDescriptorHeap(native.adapter.textureHeap().handle);

    try installNativeBindings(services);

    // The step machine is initialized at its final address: the host hooks
    // borrow this value, and the run's own loop drives it.
    var machine: NativeRun = .{
        .gpa = gpa,
        .app = app,
        .todo = todo,
        .services = services,
        .application = application,
        .handle = handle,
        .native = &native,
        .report = out,
        .step_ms = options.step_ms,
        // SAFETY: `records` is bounded by `key_count`, which starts at zero.
        .keys = undefined,
    };
    // The guards above owned the half and the GPU mount while this value was
    // being built. It is whole now, so it owns them: one owner, one release,
    // and no outer flag that has to remember a half it no longer holds.
    native_live = false;
    gpu_attached = false;
    machine.live = true;

    // The close hook and the error path use one release: blur the focus the
    // chords replay into, detach the GPU mount, then retire the adapter,
    // surface and device while the platform window is still alive.
    defer if (machine.live) machine.releaseNative();

    application.setHooks(.{
        .context = &machine,
        .on_frame = NativeRun.onFrame,
        .on_event = NativeRun.onEvent,
        .on_quit_request = NativeRun.onQuitRequest,
        // The GPU half is retired here, while the window still exists.
        .on_before_close = NativeRun.onBeforeClose,
    });
    try application.start();

    try out.emit(
        "native: title=\"{s}\" driver={s} surface={d}x{d} step_budget_ms={d} settle_ms={d} " ++
            "chord_timeout_ms={d} poll_ms={d}\n",
        .{
            native_title,
            sdl3.video.getCurrentDriverName() orelse "<null>",
            native_width,
            native_height,
            options.step_ms,
            native_settle_ms,
            native_chord_timeout_ns / std.time.ns_per_ms,
            native_idle_ms,
        },
    );
    try out.emit(
        "native: this run pushed NO SDL event; every key below arrived from an " ++
            "external controller on the caller's own display server\n",
        .{},
    );

    managed.demand.requestPresentation();
    machine.armWarmup();
    while (application.isRunning() and !machine.should_close) {
        if (!try application.step()) break;
        // A platform can close this window from inside that step, and the
        // host hook retires the GPU half before SDL destroys it.
        if (!machine.live) break;
        try machine.pump();
        // The host's own wait is the schedule this run honours: it folds in
        // the chord deadline, the frame demand and the task queue.
        const wait = try application.nextWaitMilliseconds();
        if (app.nextShortcutDeadline() != null) {
            if (wait) |ms| machine.min_host_wait_ms = @min(machine.min_host_wait_ms, ms);
        }
        const pause = @max(@min(wait orelse native_idle_ms, native_idle_ms), 1);
        try Io.sleep(io, Io.Duration.fromMilliseconds(pause), .real);
    }

    // The pixels of the last presented frame, read back out of the target the
    // two passes wrote. A window the platform closed during the hold already
    // retired the adapter, so the run says so instead of reaching into a
    // released one.
    if (!machine.live) {
        try out.emit("pixels: the window was retired during the hold\n", .{});
    } else if (machine.frames_committed != 0) {
        try capturePixels(gpa, io, &machine, options.pixel_path);
    } else {
        try out.emit("pixels: no frame was presented, so there are no pixels to read\n", .{});
    }

    const stats = machine.frameStats();
    const target = machine.frameTarget();
    const counters = try services.counters();
    try out.emit(
        "holding: frames={d} presented={d} retries={d} step={s} downs={d} ups={d} " ++
            "repeats={d} texts={d} overflow={}\n",
        .{
            machine.frames_committed,
            stats.frames_presented,
            machine.retries,
            @tagName(machine.step),
            machine.downs,
            machine.ups,
            machine.repeats,
            machine.texts,
            machine.key_overflow,
        },
    );
    try out.emit(
        "frame: committed={d} presented={d} resizes_requested={d} swapchains_recreated={d} " ++
            "extent_mismatches={d} present_out_of_date={d} scale_changes={d} target={d}x{d}\n",
        .{
            stats.frames_committed,
            stats.frames_presented,
            stats.resizes_requested,
            stats.swapchains_recreated,
            stats.extent_mismatches,
            stats.present_out_of_date,
            stats.scale_changes,
            target.width,
            target.height,
        },
    );
    try out.emit(
        "registry: toggles={d} additions={d} resets={d} removals={d}\n",
        .{ counters.toggles, counters.additions, counters.resets, counters.removals },
    );
    try out.emit("model: counter={d} visible={d} done0={} focus=\"{s}\"\n", .{
        todo.counter,
        todo.visible_count,
        todo.done[0],
        machine.focusName(),
    });

    if (machine.key_overflow) return Error.KeyLogOverflow;
    if (machine.step != .done) return Error.NativeStepsIncomplete;
    if (app.nextShortcutDeadline() != null) return Error.PendingChordLeftBehind;
    if (machine.downs != machine.ups) return Error.ReleasedKeysOutstanding;

    // The explicit close goes through the host, so the hook retires the GPU
    // half while the window is still alive.
    if (machine.live) {
        const closed = try application.closeWindow(handle);
        _ = try application.step();
        try out.emit("close: released={} window_count={d}\n", .{ closed, application.window_count });
    } else {
        try out.emit("close: the platform closed this window during the hold\n", .{});
    }
    try out.emit("retire: surface_before_window={d} frames_at_retire={d}\n", .{
        machine.retirements,
        machine.frameStats().frames_presented,
    });
    try out.emit("shortcut-native: OK\n", .{});
}

/// Inked pixels in the Oklab readback of this run's own target, counted
/// beside the clear colour and optionally written out as the sRGB image the
/// blit produced. This is a readback of what the window showed, not a
/// re-render and not a model read.
fn capturePixels(
    gpa: std.mem.Allocator,
    io: Io,
    machine: *NativeRun,
    path: ?[]const u8,
) !void {
    const pixels = try machine.native.adapter.readTarget();
    const extent = machine.native.adapter.targetExtent();
    var inked: u64 = 0;
    for (0..extent.height) |y| {
        for (0..extent.width) |x| {
            const at = (y * extent.width + x) * 4;
            if (@abs(pixels[at] - frame_api.scene.oklab_clear[0]) < 0.004 and
                @abs(pixels[at + 1] - frame_api.scene.oklab_clear[1]) < 0.004 and
                @abs(pixels[at + 2] - frame_api.scene.oklab_clear[2]) < 0.004) continue;
            inked += 1;
        }
    }
    try machine.report.emit("pixels: extent={d}x{d} inked={d}\n", .{ extent.width, extent.height, inked });
    if (path) |target_path| {
        try frame_api.writePpm(gpa, io, target_path, pixels, extent);
        try machine.report.emit("pixels: wrote {s}\n", .{target_path});
    }
}
