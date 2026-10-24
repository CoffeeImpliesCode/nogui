//! A menu, a tooltip and a drag, all three driven by REAL routed input on ONE
//! mounted `App` tree. Headless: no window, no GPU, no native popup.
//!
//! The consumer side, and what each piece owns:
//!
//!   * `nogui.overlay.Frame` — a frame-local list of (anchor, content) records.
//!     Content is built as ordinary nodes, then `resolve` places each one after
//!     layout from the CURRENT visual geometry, so a popup follows its anchor
//!     through a scroll. Paint order and hit order come from the SAME
//!     priority/insertion key, so what is on top is what receives the point.
//!   * `nogui.overlay.ModalFocus` — the menu's focus scope. Opening it records
//!     the surviving prior target; closing it restores that target instead of
//!     blurring, and refuses to restore a recycled generation. Both moves pass
//!     `App.focusObserver`, so the scope's focus change is routed and reported
//!     like every other one instead of moving focus in silence.
//!   * `nogui.drag_drop.Manager` — typed drag ownership. `can_drop` gates the
//!     commit against a MODEL value, and a release that never reaches a target
//!     still runs every callback and frees the payload exactly once.
//!   * `nogui.tooltip.Manager` — hover state plus a deadline, and NOTHING
//!     else: the Session W05 UI task service owns the timer. The consumer arms
//!     `deadline().at_ns` with `scheduleUi` and cancels that handle when a new
//!     deadline or a removed owner invalidates it. There is no tooltip
//!     scheduler anywhere in this file.
//!   * `nogui_host.menus` — the native menu model and its W10 action bridge,
//!     which resolves item enablement from the focused context.
//!
//! Run it: `zig build run-parity-menu-overlay`. `specimen` below is the ONE
//! sequence; `main` runs it with printing, the test runs the same function
//! without and then asserts the model it left behind. The evidence is the run
//! itself, not a second copy of it.
//!
//! `--native` mounts the SAME `MenuView`, the same `Session`, the same W05
//! timer and the same `App` on a real owned toplevel: a `host.Application`
//! window over `v7_frame.NativeFrame`, presenting the committed tree into
//! that window's swapchain image. It fabricates NOTHING. Every pointer, key
//! and focus change it needs is published as an exact command for an
//! external X11 controller to run against that one window, and then waited
//! for on the host's own delivery — the request is what a person has to do,
//! the model change is the proof, and the wait is bounded, so an unanswered
//! request fails the run by name. Its W05 deadlines are real instants on the
//! production monotonic clock, reached by waiting rather than by moving one.
//! It reads its own frame back out of the Oklab target those passes wrote, so
//! every pixel it reports about an overlay or a tooltip is a pixel that
//! reached the window.
//!
//! Three limits are reported, not papered over:
//!
//!   1. Nothing here is an OS popup window. `window_contract.Kind.menu` and
//!      `.tooltip` need a live parent `WindowHandle`; this file owns none, in
//!      either arm, so the menu and the tooltip are in-window overlay
//!      subtrees — W16 popups on a real window, not the W22 OS popup, which
//!      stays a separate piece of work. The headless run's raster at the end
//!      is a CPU walk of the committed tree, not a GPU or compositor frame;
//!      the `--native` run's pixels are a GPU readback of a presented frame.
//!   2. `--native` needs a display server and a GPU. The default run needs
//!      neither: it opens no window, starts no SDL and never reaches a
//!      shader file.
const std = @import("std");
const sdl3 = @import("sdl3");

const nogui = @import("nogui");
const host = @import("nogui_host");
const frame_mod = @import("v7_frame");
const font_bytes = @import("font_bytes").bytes;

const overlay = nogui.overlay;
const drag_drop = nogui.drag_drop;
const tooltip = nogui.tooltip;
const action = nogui.action;
const task = nogui.task;
const focus = nogui.focus;
const event = nogui.event;
const input = nogui.input;
const widget = nogui.widget;
const window_contract = nogui.window_contract;
const App = nogui.App;
const DrawCtx = nogui.DrawCtx;
const Session = nogui.Session;
const WidgetId = nogui.WidgetId;
const FrameNodeId = nogui.FrameNodeId;
const WindowSize = nogui.geometry.WindowSize;
const PixelScale = nogui.geometry.PixelScale;
const NativeFrame = frame_mod.NativeFrame;
const noapi = frame_mod.noapi;
const menus = host.menus;

/// The committed surface, and the viewport the overlay frame fits into.
const surface: nogui.Size = .{ .width = 240, .height = 160 };
const overlay_viewport: widget.Rect = .{ .w = surface.width, .h = surface.height };
/// Cells in the windowless raster. 4x8 px per cell over the committed surface.
pub const raster_columns = 60;
pub const raster_rows = 20;

const key_file = "menu-file";
const key_hint = "menu-hint";
const key_anchor = "menu-anchor";
const key_card = "menu-card";
const key_drop = "menu-drop";
const key_menu = "menu-content";
const key_item = "menu-item";
const key_tip = "menu-tip";

/// The description the tooltip publishes for the hint, and the hover delay in
/// nanoseconds of the injected clock. The delay is a MODEL constant: the run
/// moves the clock, it never sleeps.
const hint_description = "Drag the card onto the target";
const hint_delay_ns: u64 = 500 * std.time.ns_per_ms;
/// A pointer must travel this far before a press becomes a drag.
const drag_threshold: f32 = 4;

/// The overlay records' priorities. The higher one paints and hits on top,
/// and the native arm asserts that on the GPU rather than in a comment.
const menu_priority: u31 = 1;
const tip_priority: u31 = 5;

// ── the `--native` arm ──────────────────────────────────────────────

/// The native window asks for the committed surface's own logical size, so
/// the presented geometry and the headless geometry are the same numbers
/// rather than two scales of one scene. `Native` refuses the run outright if
/// the platform hands back anything else.
const native_width: u32 = 240;
const native_height: u32 = 160;
const native_title = "nogui menu overlay native specimen";
/// The private auxiliary window a controller owns for itself, and the only
/// other window this protocol ever names. The focus-transfer step asks the
/// controller to raise THIS window, which makes the focus loss below a real
/// platform event rather than something this process invented.
const native_aux_title = "nogui-menu-overlay-controller-anchor";
const native_app_id: [:0]const u8 = "dev.nogui.examples.parity.menu-overlay";
/// Host iterations spent waiting for the one frame a step asked for, and
/// acquires spent waiting for a swapchain that was out of date. Both are
/// bounds, not timeouts this file may quietly grow past.
const frame_polls: u32 = 8;
const acquire_polls: u32 = 8;
/// One controller script is this many bytes and this many steps. A step list
/// is data from another process, so it is bounded twice.
const controller_script_limit: usize = 4096;
const controller_step_limit: usize = 64;

/// The SPIR-V the presented path records with, relative to the working
/// directory, which for a `zig build` run step is the repo root. Only
/// `--native` ever opens one of these files.
const default_quad_vert = "shaders/quad_vert.spv";
const default_quad_frag = "shaders/quad_frag.spv";
const default_sort_comp = "shaders/sort_comp.spv";
const default_fullscreen_vert = "shaders/fullscreen_vert.spv";
const default_blit_oklab = "shaders/blit_oklab.spv";

/// The fills the two overlays author, as sRGB, and the Oklab the frame
/// module's own public conversion says they land in. The readback probes
/// compare against THESE, so a pixel claim names a fill instead of a
/// hand-tuned colour.
const menu_fill: [4]f32 = .{ 0.20, 0.22, 0.30, 1 };
const tip_fill: [4]f32 = .{ 0.32, 0.28, 0.16, 1 };
/// Two fills this far apart in Oklab can never be confused for one another,
/// and a fill is this close to itself is a match and not a coincidence.
const lab_match_tolerance: f32 = 0.01;
const lab_distinct_tolerance: f32 = 0.02;
/// Logical units a probe region is inset by, so no rounded corner, border or
/// antialiased edge is ever sampled as a fill.
const probe_inset: f32 = 3;

fn keyOf(name: []const u8) nogui.ComponentKey {
    return .{ .static = name };
}

/// The payload a drag carries. `drag_drop` type-erases it and refuses to hand
/// a `PayloadView` to a reader of any other type.
pub const Card = struct {
    title: []const u8,
    /// Counts payload destructions, so a leaked or double-freed payload shows
    /// up as a count that is not exactly one per drag.
    destructions: *u32,

    pub fn deinit(self: *Card) void {
        self.destructions.* += 1;
    }
};

/// The model the W10 action bridge consults for menu enablement.
pub const Editor = struct {
    can_undo: bool = true,
    can_redo: bool = false,

    fn undo(_: *Editor, _: *const void, _: *Session) !void {}
    fn undoAvailable(self: *const Editor, _: *Session) action.Availability {
        return if (self.can_undo) .available else .disabled;
    }
    fn redo(_: *Editor, _: *const void, _: *Session) !void {}
    fn redoAvailable(self: *const Editor, _: *Session) action.Availability {
        return if (self.can_redo) .available else .disabled;
    }

    /// The Minimize row of the bar carries the native ordinal rather than a
    /// declared name, and it reaches this model because the model registered
    /// the name that ordinal derives.
    fn minimize(_: *Editor, _: *const void, _: *Session) !void {}
    fn minimizeAvailable(_: *const Editor, _: *Session) action.Availability {
        return .available;
    }
};

const UndoAction = action.Action(void, "edit.undo");
const RedoAction = action.Action(void, "edit.redo");
const MinimizeAction = action.Action(void, menus.SystemAction.minimize.actionName());

/// A deterministic clock shared by the tooltip manager and the Session task
/// service, so the delay the tooltip computes and the deadline the service
/// waits for are the same instant. Nothing in this example sleeps.
const Ticks = struct {
    value: i96 = 0,

    fn now(raw: *anyopaque) i96 {
        const self: *Ticks = @ptrCast(@alignCast(raw));
        return self.value;
    }
};

/// What one W05 delivery is told. The token is the tooltip's own generation, so
/// a timer left over from a replaced deadline expires nothing.
pub const TipWork = struct {
    token: u64 = 0,
};

/// Read-out of the W05 tooltip owner, so the assertions read the model the
/// timer wrote rather than a counter the test kept.
pub const TipStats = struct {
    /// Handler invocations, delivered or not.
    delivered: u32 = 0,
    /// Invocations whose token still matched AND whose owner was still eligible.
    fired: u32 = 0,
    /// Visibility when the owner is read.
    visible: bool = false,
};

/// The W05 owner. It is a Session model, so the weak-owner check in
/// `scheduleUi` is the same one every other UI task uses, and a delivery
/// cannot run after the model is released.
pub const TipTimer = struct {
    view: *MenuView,
    token: u64 = 0,
    stats: TipStats = .{},

    /// The delivered W05 UI timer. It borrows the view's tooltip manager and
    /// the App's committed tree, and asks for one more frame when it changed
    /// something. It never schedules anything itself.
    pub fn expire(self: *TipTimer, work: *TipWork, session: *Session) void {
        self.stats.delivered += 1;
        const tree = self.view.app.tree_ptr orelse return;
        if (!self.view.tip.expire(work.token, tree)) return;
        self.stats.fired += 1;
        self.view.tip_shows += 1;
        session.requestRedraw(self.view.app.window) catch unreachable;
    }

    pub fn read(self: *const TipTimer, out: *TipStats) !void {
        out.* = self.stats;
        out.visible = self.view.tip.visible();
    }
};

/// Every drag counter at one instant. `since` reads a pair of instants as ONE
/// drag's counters, so an assertion can name the drag it means: this run
/// cancels three drags three different ways, and a total would charge the
/// refused release with the outside cancel that came before it.
pub const DragSnapshot = struct {
    enters: u32 = 0,
    moves: u32 = 0,
    leaves: u32 = 0,
    checks: u32 = 0,
    cancels: u32 = 0,
    drops: u32 = 0,
    frees: u32 = 0,
    card_clicks: u32 = 0,
    foreign_reads: u32 = 0,

    /// What the drag that ran between `base` and this instant produced.
    pub fn since(self: DragSnapshot, base: DragSnapshot) DragSnapshot {
        return .{
            .enters = self.enters - base.enters,
            .moves = self.moves - base.moves,
            .leaves = self.leaves - base.leaves,
            .checks = self.checks - base.checks,
            .cancels = self.cancels - base.cancels,
            .drops = self.drops - base.drops,
            .frees = self.frees - base.frees,
            .card_clicks = self.card_clicks - base.card_clicks,
            .foreign_reads = self.foreign_reads - base.foreign_reads,
        };
    }
};

/// The mounted root component. It owns the three transient surfaces, the
/// overlays they are placed by, and the model outcomes the run reports. Every
/// counter is written by the code that handles a ROUTED event, a W05 delivery
/// or a drag callback; nothing here is written by a test.
pub const MenuView = struct {
    const Self = @This();

    /// Non-owning back pointers, set before `mountRoot`. The App keeps a
    /// `*MenuView`; the view needs the App's committed tree, focus manager and
    /// window id. Neither side owns the other.
    app: *App = undefined,
    session: *Session = undefined,
    /// The W05 timer owner, a Session model created before the first arm.
    timer: nogui.Model(TipTimer) = undefined,

    // ── routed input ──
    /// One per event the App routed to a node this view owns, counted at the
    /// target phase, so a routed count is a routing count and not a count of
    /// the deliveries a walk made on the way there.
    routed: u32 = 0,
    /// Releases the App routed at the target phase. A request that asks for
    /// ONE click must deliver ONE of these, so this separates "the platform
    /// sent two press/release pairs" from "one release activated twice".
    mouse_ups: u32 = 0,
    /// Activations the App routed at the target phase. The App turns a release
    /// into exactly one of these, so this is what an `on_click` is counted
    /// against, counted beside the callback it drives rather than instead of it.
    activations: u32 = 0,
    /// Moves the App routed at the target phase. A request that asks for one
    /// motion must deliver one of these, which `routed` cannot promise: a
    /// routed count also moves for the focus and activation dispatches the
    /// same press produces, so a wait on it ends before the event it was
    /// written for.
    pointer_moves: u32 = 0,

    // ── the scene ──
    open_menu: bool = false,
    show_hint: bool = true,
    show_drop: bool = true,
    /// The MODEL value the drop target publishes. A release the target refuses
    /// must leave the dropped title untouched.
    accept_drops: bool = true,
    filler_rows: usize = 3,
    scroll: nogui.widget.ScrollState = .{},

    // ── overlays ──
    frame: overlay.Frame = undefined,
    modal: overlay.ModalFocus = .{},

    // ── drag ──
    drag: drag_drop.Manager = .{},
    /// One per drag callback the manager invoked on this view's handler. The
    /// five are kept apart because a drop that entered and was then refused
    /// still cancelled, and a run has to be able to say which happened.
    drag_enters: u32 = 0,
    drag_moves: u32 = 0,
    drag_leaves: u32 = 0,
    drag_checks: u32 = 0,
    drag_cancels: u32 = 0,
    /// A wrong-typed read of a typed payload, which the marker must refuse.
    foreign_reads: u32 = 0,
    /// The model outcome of a committed drop.
    drops: u32 = 0,
    dropped_title: [24]u8 = @splat(0),
    dropped_len: usize = 0,
    payload_frees: u32 = 0,
    /// Cancellations caused by a revoked capture: the pointer left the window
    /// or the window lost focus.
    outside_cancels: u32 = 0,
    /// A move that stayed under the threshold, so no drag existed yet.
    under_threshold_moves: u32 = 0,

    // ── tooltip ──
    tip: tooltip.Manager = undefined,
    tip_handle: ?task.Handle = null,
    tip_token: u64 = 0,
    tip_arms: u32 = 0,
    tip_cancels: u32 = 0,
    tip_shows: u32 = 0,
    tip_bounds_set: bool = false,

    // ── menu and focus ──
    menu_opens: u32 = 0,
    menu_closes: u32 = 0,
    file_clicks: u32 = 0,
    item_clicks: u32 = 0,
    card_clicks: u32 = 0,
    /// One per close that left a live target behind, so a menu that hands
    /// focus back is counted separately from one that only blurs.
    focus_restores: u32 = 0,
    focus_changes: u32 = 0,
    focus_current: ?WidgetId = null,

    menu_placement: nogui.widget.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    menu_escaped_clip: bool = false,
    scroll_offset: f32 = 0,
    scrolled_by: f32 = 0,
    tip_deadline_ns: i96 = 0,
    service_deadline_ns: i96 = 0,
    tip_pending_early: bool = false,
    tip_at_show: TipStats = .{},
    /// Arm and cancel counts snapshotted where they are observed, because a
    /// later frame in the run re-arms the timer on purpose.
    arms_at_show: u32 = 0,
    arms_at_reenter: u32 = 0,
    cancels_at_reenter: u32 = 0,
    /// The tooltip's EMITTED layer is above the menu's, and the menu's own
    /// band clears the highest layer the application authors. Read as two
    /// comparisons, not as a constant this file picked.
    tip_paints_above: bool = false,
    overlap_point: ?[2]f32 = null,
    overlap_winner: u8 = 0,
    /// The glyph the engine's OWN layout-box hit test names at the item point.
    /// Reported beside the placed pick, never asserted to a fixed value: it is
    /// the pre-seam routing answer, and this file does not pin it.
    raw_pick_glyph: u8 = 0,
    /// The glyph the overlay-aware resolution names at the same point.
    placed_pick_glyph: u8 = 0,
    focus_after_open: ?WidgetId = null,
    focus_after_escape: ?WidgetId = null,
    reenter_deadline_ns: i96 = 0,
    retire_deliveries: u32 = 0,
    /// Visibility right after the retired owner's deadline passed, which is
    /// the claim that matters: the stale timer delivered nothing. The run's
    /// closing frame shows a tooltip again, so the end-of-run value is not it.
    retire_visible: bool = true,
    outside_cancel: DragSnapshot = .{},
    refused: DragSnapshot = .{},
    accepted: DragSnapshot = .{},

    pub fn init(
        self: *Self,
        gpa: std.mem.Allocator,
        app: *App,
        session: *Session,
        clock: nogui.Clock,
    ) void {
        self.* = .{
            .app = app,
            .session = session,
            .frame = overlay.Frame.init(gpa),
            .tip = tooltip.Manager.init(gpa, clock),
        };
    }

    /// The title a committed drop actually delivered. Copied out of the typed
    /// payload, which is released as soon as the callback returns.
    pub fn droppedTitle(self: *const Self) []const u8 {
        return self.dropped_title[0..self.dropped_len];
    }

    /// Every drag counter the run has produced SO FAR. Read it through
    /// `DragSnapshot.since` to name one drag out of that total.
    pub fn dragSnapshot(self: *const Self) DragSnapshot {
        return .{
            .enters = self.drag_enters,
            .moves = self.drag_moves,
            .leaves = self.drag_leaves,
            .checks = self.drag_checks,
            .cancels = self.drag_cancels,
            .drops = self.drops,
            .frees = self.payload_frees,
            .card_clicks = self.card_clicks,
            .foreign_reads = self.foreign_reads,
        };
    }

    /// The owner of every allocation this component made. The App does not
    /// call a component's teardown, so the consumer does it, after the App is
    /// gone and before the view's memory is.
    pub fn release(self: *Self) void {
        // Cancel first, so an active drag emits its cancellation instead of
        // being released silently.
        self.drag.cancel(.{ .mouse = .left }, self.dragHandler());
        self.drag.deinit();
        self.tip.deinit();
        self.frame.deinit();
    }

    /// One frame of this scene.
    ///
    /// The placement records below keep the authored priorities
    /// (`tip_priority` above `menu_priority`), and those are what
    /// `overlay.Frame` resolves. ONE `(priority, registration)` key decides
    /// everything downstream: the band `finalizePaintOrder` assigns, the
    /// `widget.effectiveLayer` the painter emits, the hit test and the App's
    /// own routing all read it. This file never asserts an ordering by naming
    /// a constant; it compares the emitted layers and measures pixels.
    ///
    /// The ORDER of the calls below is the ordinary one — menu bar, scroller,
    /// menu, tooltip — and is deliberately NOT a paint-order lever. Placement
    /// moves the content and the band raises it. Reordering the builder to
    /// make a result appear would hide a frame that did not produce it, so
    /// nothing below is a workaround and nothing below is a lever.
    pub fn draw(self: *Self, ctx: *DrawCtx) !void {
        // The menu bar sits outside the scroller, so the tooltip's owner keeps
        // a stable rect while the menu's anchor scrolls underneath it.
        _ = try ctx.row(.{ .height = 20, .gap = 4 });
        _ = try ctx.button(.{
            .key = keyOf(key_file),
            .label = "File",
            .height = 18,
            .on_click = Self.onFileClicked,
        });
        if (self.show_hint) {
            _ = try ctx.button(.{
                .key = keyOf(key_hint),
                .label = "?",
                .height = 18,
            });
        }
        ctx.pop();

        // The scrolling container. Its content is taller than the box, so a
        // real wheel event over the anchor has somewhere to scroll to.
        _ = try ctx.column(.{ .height = 100, .scroll_state = &self.scroll });
        const anchor = try ctx.button(.{ .key = keyOf(key_anchor), .label = "Anchor", .height = 22 });
        _ = try ctx.button(.{
            .key = keyOf(key_card),
            .label = "card",
            .height = 22,
            .on_click = Self.onCardClicked,
        });
        if (self.show_drop) {
            _ = try ctx.button(.{ .key = keyOf(key_drop), .label = "drop here", .height = 22 });
        }
        for (0..self.filler_rows) |_| {
            _ = try ctx.spacer(.{ .size = 30 });
        }
        ctx.pop();

        // The two overlay contents, built like any other node: the menu
        // first, the tooltip after it, in the ordinary reading order of this
        // scene. The frame repositions them after layout and assigns each one
        // its band; the ORDER of these calls is deliberately NOT a paint-order
        // lever, because the band is what decides what is on top.
        var menu_content: ?FrameNodeId = null;
        if (self.open_menu) {
            const content = try ctx.column(.{
                .key = keyOf(key_menu),
                .position = .absolute,
                .width = 70,
                .height = 40,
                .fill = menu_fill,
            });
            _ = try ctx.button(.{
                .key = keyOf(key_item),
                .label = "Open",
                .height = 20,
                .on_click = Self.onItemClicked,
            });
            ctx.pop();
            menu_content = content;
        }
        var tip_content: ?FrameNodeId = null;
        if (self.show_hint and self.tip.visible()) {
            const content = try ctx.column(.{
                .key = keyOf(key_tip),
                .position = .absolute,
                .width = 240,
                .height = 22,
                .fill = tip_fill,
            });
            _ = try ctx.label(.{ .text = hint_description });
            ctx.pop();
            tip_content = content;
        }

        // Both records, registered once the content they place exists. The
        // priorities are the ones the frame resolves: the tooltip's is above
        // the menu's, and both bands start above the application's highest
        // authored layer, so both popups paint over ordinary content.
        const anchor_id = ctx.widgetIdOf(anchor) orelse return error.MissingAnchor;
        if (menu_content) |content| {
            try ctx.place(.{
                .anchor = anchor_id,
                .content = ctx.widgetIdOf(content) orelse return error.MissingMenu,
                .side = .below,
                .gap = 2,
                .clip = .window_escape,
                .priority = menu_priority,
                .modal = true,
            });
        }
        if (tip_content) |content| {
            try ctx.place(.{
                .anchor = anchor_id,
                .content = ctx.widgetIdOf(content) orelse return error.MissingTip,
                .side = .below,
                .gap = 10,
                .clip = .window_escape,
                .priority = tip_priority,
            });
        }
    }

    // ── the ordinary control callbacks ──

    fn onFileClicked(self: *Self) void {
        self.file_clicks += 1;
        self.open_menu = true;
        self.menu_opens += 1;
    }

    fn onItemClicked(self: *Self) void {
        self.item_clicks += 1;
        // A menu item dismisses the menu, the way a real one does.
        self.closeMenu();
    }

    fn onCardClicked(self: *Self) void {
        self.card_clicks += 1;
    }

    // ── routed input ──

    /// The App routes every event through the tree. The root owns every node it
    /// builds, so this is called once per owned node on the path; the target
    /// phase of the target node is the one delivery the consumer acts on.
    pub fn onRoutedEvent(self: *Self, context: *event.DispatchContext) void {
        if (context.phase != .target) return;
        if (context.current_target != context.target) return;
        const tree = self.app.tree_ptr orelse return;
        self.routed += 1;
        switch (context.event.*) {
            .mouse_move => |move| self.onPointerMove(
                tree,
                .{ move.x, move.y },
                context.target,
            ),
            .mouse_down => |down| self.onPointerDown(tree, .{ down.x, down.y }, context),
            .mouse_up => |up| {
                self.mouse_ups += 1;
                self.onPointerUp(tree, .{ .mouse = up.button }, context);
            },
            .key_down => |key| self.onKeyDown(key, context),
            .capture_lost => |lost| self.onCaptureLost(lost.pointer),
            .mouse_leave, .window_focus_lost => self.tip.cancel(),
            .activate => self.activations += 1,
            else => {},
        }
    }

    fn onPointerMove(self: *Self, tree: *const nogui.widget.WidgetTree, point: [2]f32, target: ?FrameNodeId) void {
        self.pointer_moves += 1;
        const hit = if (target) |node| stableAncestor(tree, node) else null;
        // A real move feeds the drag exactly as a real move feeds the controls
        // below it: the manager decides whether the threshold is crossed.
        self.drag.pointerMove(
            tree,
            .{ .mouse = .left },
            point,
            hit,
            self.dragHandler(),
        );
        // The tooltip's own state machine runs on the routed position, so a
        // leave really is a leave and a re-enter really re-arms the delay.
        self.tip.pointerMove(hit, point);
        const hovered = hit orelse return;
        const owner = self.widget(key_hint) orelse return;
        if (hovered.eql(owner)) {
            self.tip.hover(owner, hint_description, hint_delay_ns, true) catch return;
        }
    }

    fn onPointerDown(
        self: *Self,
        tree: *const nogui.widget.WidgetTree,
        point: [2]f32,
        context: *event.DispatchContext,
    ) void {
        // `context.target` is the node the App routed this pointer to, already
        // resolved against the placed overlay geometry. Nothing is refused and
        // nothing is delivered by hand: where a popup covers the card, the App
        // routed the popup.
        const target = stableAncestor(tree, context.target) orelse return;
        const card = self.widget(key_card) orelse return;
        if (!target.eql(card)) return;
        self.drag.begin(Card, self.app.gpa, card, .{ .mouse = .left }, point, drag_threshold, .{
            .title = "notes",
            .destructions = &self.payload_frees,
        }) catch return;
    }

    fn onPointerUp(
        self: *Self,
        tree: *const nogui.widget.WidgetTree,
        pointer: event.PointerId,
        context: *event.DispatchContext,
    ) void {
        // The App's release path is the only activation path: it compares the
        // press target with the release target, so a click that landed on the
        // placed overlay activates the overlay exactly once.
        _ = self.drag.pointerRelease(
            tree,
            pointer,
            stableAncestor(tree, context.target),
            self.dragHandler(),
        );
    }

    fn onKeyDown(self: *Self, key: event.KeyEvent, context: *event.DispatchContext) void {
        if (key.key != .escape) return;
        if (!self.open_menu) return;
        // The menu owns the keyboard while it is open, so the engine's own
        // escape default (a plain blur) must not run.
        context.preventDefault();
        self.closeMenu();
    }

    /// A revoked capture with no native position: the pointer left the window
    /// or the window lost focus. The drag is cancelled here, never committed.
    fn onCaptureLost(self: *Self, pointer: event.PointerId) void {
        self.drag.cancel(pointer, self.dragHandler());
        self.outside_cancels += 1;
    }

    // ── the menu's focus scope ──

    fn closeMenu(self: *Self) void {
        // Restore the focus scope BEFORE the content leaves the tree: the
        // prior target is only restorable while it is still live.
        const had_scope = self.modal.content != null;
        const tree = self.app.tree_ptr;
        if (tree) |committed| {
            self.modal.close(&self.app.focus_manager, committed, self.app.focusObserver());
        }
        self.open_menu = false;
        self.menu_closes += 1;
        if (had_scope and self.app.focus_manager.current != null) self.focus_restores += 1;
    }

    pub fn onFocusChanged(raw: *anyopaque, change: focus.Change) void {
        const self: *Self = @ptrCast(@alignCast(raw));
        self.focus_changes += 1;
        self.focus_current = change.current;
    }

    // ── per-frame work, after publication ──

    /// Everything a consumer does between frames: keep the modal scope in step
    /// with the model, retire what the tree retired, and keep the W05 timer in
    /// step with the tooltip's deadline. Placement is NOT here: the popups are
    /// registered during the draw through `ctx.place`, and the App resolves
    /// them after layout, so this consumer never routes a point itself.
    pub fn afterFrame(self: *Self) !void {
        const committed = self.app.tree_ptr orelse return;
        const tree: *const nogui.widget.WidgetTree = committed;

        // The modal scope follows the model: opening takes the focus, closing
        // gives it back to the surviving prior target.
        if (self.open_menu and self.modal.content == null) {
            if (self.widget(key_item)) |item| {
                // `App.focusObserver` is the App's own observer: taking the
                // scope routes focus_out/focus_in and reports the change to
                // `App.focus_observer`, which is this view. The move is the
                // engine's own, not a write into the model.
                const observer = self.app.focusObserver();
                if (self.modal.open(&self.app.focus_manager, tree, item, observer)) {
                    self.focus_after_open = self.app.focus_manager.current;
                }
            }
        }

        // Retirement: a source, a target or an owner the tree dropped cancels
        // the work that belonged to it.
        self.drag.reconcile(tree, self.dragHandler());
        self.tip.reconcile(tree);
        try self.syncTooltip(committed);
    }

    /// Arm or cancel W05 work after routing input, before the next frame.
    pub fn afterInput(self: *Self) !void {
        const committed = self.app.tree_ptr orelse return;
        try self.syncTooltip(committed);
    }

    /// The tooltip's delay is a W05 UI timer, never a private scheduler. A new
    /// deadline, or an owner the tree retired, cancels the pending job.
    fn syncTooltip(self: *Self, committed: *nogui.widget.WidgetTree) !void {
        const session = self.session;
        const deadline = self.tip.deadline();
        if (self.tip_handle != null) {
            const stale = deadline == null or deadline.?.token != self.tip_token;
            if (stale) {
                _ = session.cancelTask(&self.tip_handle.?);
                self.tip_handle = null;
                self.tip_cancels += 1;
            }
        }
        // A hoverable tooltip needs its resolved bounds, published every frame
        // it is placed, so the pointer can move ONTO the content without
        // dismissing it. A visible tooltip has no pending deadline, so this
        // runs before the deadline check below.
        if (self.tipContent()) |content| {
            if (self.frame.placement(committed, content)) |placement| {
                self.tip.setBounds(placement.rect);
                self.tip_bounds_set = true;
            }
        }
        const current = deadline orelse return;
        if (self.tip_handle == null) {
            var work: TipWork = .{ .token = current.token };
            self.tip_token = current.token;
            self.tip_handle = try session.scheduleUi(
                TipWork,
                TipTimer,
                TipTimer.expire,
                self.timer.weak(),
                &work,
                current.at_ns,
            );
            self.tip_arms += 1;
        }
    }

    // ── drag callbacks: the only writers of the drag model ──

    fn dragHandler(self: *Self) drag_drop.Handler {
        return .{
            .user = @ptrCast(self),
            .enter = onDragEnter,
            .move = onDragMove,
            .leave = onDragLeave,
            .can_drop = onDragCanDrop,
            .drop = onDragDrop,
            .cancel = onDragCancel,
        };
    }

    fn onDragEnter(raw: *anyopaque, _: WidgetId, payload: drag_drop.PayloadView) void {
        const self: *Self = @ptrCast(@alignCast(raw));
        // The payload is typed: a reader of any other type gets nothing, and
        // the right type reads the same view successfully.
        if (payload.get(u32) == null and payload.get(Card) != null) self.foreign_reads += 1;
        self.drag_enters += 1;
    }

    fn onDragMove(raw: *anyopaque, _: WidgetId, _: drag_drop.PayloadView) void {
        const self: *Self = @ptrCast(@alignCast(raw));
        self.drag_moves += 1;
    }

    fn onDragLeave(raw: *anyopaque, _: WidgetId, _: drag_drop.PayloadView) void {
        const self: *Self = @ptrCast(@alignCast(raw));
        self.drag_leaves += 1;
    }

    fn onDragCanDrop(raw: *anyopaque, _: WidgetId, _: drag_drop.PayloadView) bool {
        const self: *Self = @ptrCast(@alignCast(raw));
        self.drag_checks += 1;
        return self.accept_drops;
    }

    fn onDragDrop(raw: *anyopaque, _: WidgetId, payload: drag_drop.PayloadView) void {
        const self: *Self = @ptrCast(@alignCast(raw));
        const card = payload.get(Card) orelse return;
        const title = card.title;
        const bounded = @min(title.len, self.dropped_title.len);
        @memcpy(self.dropped_title[0..bounded], title[0..bounded]);
        self.dropped_len = bounded;
        self.drops += 1;
    }

    fn onDragCancel(raw: *anyopaque, _: WidgetId, _: drag_drop.PayloadView) void {
        const self: *Self = @ptrCast(@alignCast(raw));
        self.drag_cancels += 1;
    }

    // ── resolution helpers over the committed tree ──

    pub fn widget(self: *Self, name: []const u8) ?WidgetId {
        return self.app.widgetIdForKey(.root, keyOf(name));
    }

    fn tipContent(self: *Self) ?WidgetId {
        if (!self.tip.visible()) return null;
        return self.widget(key_tip);
    }
};

/// The nearest keyed ancestor of `node`. The App routes to a dense node, and a
/// consumer names a widget, so every handler converts the routed node once —
/// through the public parent chain, never through a private hit test.
fn stableAncestor(tree: *const widget.WidgetTree, node: ?FrameNodeId) ?WidgetId {
    var current = node orelse return null;
    while (true) {
        const entry = tree.nodeConst(current) orelse return null;
        if (entry.widget_id) |id| return id;
        if (entry.parent == .root) return null;
        current = entry.parent;
    }
}

/// True when `node` is `root` or lives inside `root`'s subtree. The overlay
/// frame returns a node, not an overlay identity, so the consumer resolves
/// which overlay owns a hit by walking the public parent chain.
fn withinSubtree(
    tree: *const widget.WidgetTree,
    node: FrameNodeId,
    root: FrameNodeId,
) bool {
    var current = node;
    while (true) {
        if (current == root) return true;
        const entry = tree.nodeConst(current) orelse return false;
        if (entry.parent == .root) return false;
        current = entry.parent;
    }
}

/// The intersection of two placed overlay rects, or null when they do not
/// overlap. Used to find a point inside BOTH overlays, where the priority
/// ordering is the only thing that decides the hit.
fn overlapRect(a: widget.Rect, b: widget.Rect) ?widget.Rect {
    const x = @max(a.x, b.x);
    const y = @max(a.y, b.y);
    const right = @min(a.x + a.w, b.x + b.w);
    const bottom = @min(a.y + a.h, b.y + b.h);
    if (right <= x or bottom <= y) return null;
    return .{ .x = x, .y = y, .w = right - x, .h = bottom - y };
}

/// The named widgets of this scene, and the character that stands for each in
/// the windowless raster. A node this scene does not name is never printed, so
/// the raster cannot imply a widget the tree does not have.
const glyph_names = [_]struct { key: []const u8, glyph: u8 }{
    .{ .key = key_file, .glyph = 'F' },
    .{ .key = key_hint, .glyph = '?' },
    .{ .key = key_anchor, .glyph = 'A' },
    .{ .key = key_card, .glyph = 'C' },
    .{ .key = key_drop, .glyph = 'D' },
    .{ .key = key_menu, .glyph = 'M' },
    .{ .key = key_item, .glyph = 'o' },
    .{ .key = key_tip, .glyph = 'T' },
};

fn glyphOf(view: *MenuView, id: WidgetId) ?u8 {
    for (glyph_names) |entry| {
        if (view.widget(entry.key)) |known| {
            if (known.eql(id)) return entry.glyph;
        }
    }
    return null;
}

/// One painted box in the windowless raster.
const Stamp = struct {
    rect: widget.Rect,
    order: u64,
    glyph: u8,
};

const Glyph = struct { id: WidgetId, glyph: u8 };

/// The scenario owns its Session, App, view and W05 timer on the heap: the App
/// retains a `*Session` and a `*MenuView`, and the W05 owner retains the view,
/// so returning any of them by value would dangle.
pub const Scenario = struct {
    gpa: std.mem.Allocator,
    ticks: Ticks,
    session: *Session,
    app: *App,
    view: *MenuView,
    registry: action.Registry,
    editor: nogui.Model(Editor),
    timer: nogui.Model(TipTimer),
    /// The `--native` arm's host, when it opened a window on THIS App. It is
    /// borrowed: `Native` creates it, hands the handle here, and `deinit`
    /// closes the window and drops the host BEFORE the task service, because
    /// the host unregisters its task wake on the way out and the Session has
    /// to outlive that call. Null in the headless arm, which owns no window.
    host: ?*host.Application = null,
    host_handle: ?window_contract.WindowHandle = null,
    /// The clock both the W05 task service and the tooltip manager read. The
    /// headless arm owns it by hand through `ticks`; the native arm passes the
    /// production monotonic clock, so its deadlines are real instants and its
    /// W05 jobs fire on the service's own schedule.
    clock: nogui.Clock = undefined,

    /// True while this scenario's App is mounted in a live host window.
    pub fn hosted(self: *const Scenario) bool {
        return self.host != null;
    }

    /// The headless scenario: an injected clock this scenario moves by hand,
    /// which is what makes the default run deterministic and sleep-free.
    pub fn init(gpa: std.mem.Allocator) !*Scenario {
        return initWithClock(gpa, null);
    }

    /// The same scenario on a clock the caller owns. `clock` null means the
    /// injected clock above; a real clock is what `--native` uses, because a
    /// tooltip deadline nobody advances is a deadline that arrives on its own.
    pub fn initWithClock(gpa: std.mem.Allocator, clock: ?nogui.Clock) !*Scenario {
        const self = try gpa.create(Scenario);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .ticks = .{},
            .session = undefined,
            .app = undefined,
            .view = undefined,
            .registry = undefined,
            .editor = undefined,
            .timer = undefined,
            .host = null,
            .host_handle = null,
        };
        // The W05 task service and the tooltip manager read the SAME clock, so
        // the instant the tooltip computes is the instant the service waits
        // for — whichever clock that is.
        self.clock = clock orelse nogui.Clock.injected(&self.ticks, Ticks.now);
        self.session = try gpa.create(Session);
        errdefer gpa.destroy(self.session);
        self.session.* = try Session.init(gpa);
        try self.session.startTasks(self.clock);
        errdefer self.session.deinit() catch unreachable;

        self.app = try gpa.create(App);
        errdefer gpa.destroy(self.app);
        self.app.* = try App.init(gpa, self.session);
        errdefer self.app.deinit();

        self.view = try gpa.create(MenuView);
        errdefer gpa.destroy(self.view);
        self.view.init(gpa, self.app, self.session, self.clock);
        errdefer self.view.release();
        // The App owns placement: it resolves this caller-owned frame against
        // the tree it publishes, every frame, before any custom paint.
        self.app.setOverlayFrame(&self.view.frame);
        try self.app.mountRoot(MenuView, self.view);
        // Focus notifications are the consumer's own observation of what the
        // engine did with focus.
        self.app.focus_observer = .{
            .user = @ptrCast(self.view),
            .on_focus = MenuView.onFocusChanged,
        };

        self.registry = try action.Registry.init(gpa, self.session);
        errdefer self.registry.deinit();
        try self.registry.register(UndoAction);
        try self.registry.register(RedoAction);
        try self.registry.register(MinimizeAction);

        var initial: Editor = .{};
        self.editor = try self.session.create(Editor, &initial);
        errdefer self.session.release(Editor, &self.editor) catch unreachable;

        var tip: TipTimer = .{ .view = self.view };
        self.timer = try self.session.create(TipTimer, &tip);
        errdefer self.session.release(TipTimer, &self.timer) catch unreachable;
        self.view.timer = self.timer;
        return self;
    }

    pub fn deinit(self: *Scenario) void {
        const gpa = self.gpa;
        const view = self.view;
        // Retire the pending W05 job and the service while the view is still
        // alive: a delivered handler borrows it.
        if (view.tip_handle) |*handle| {
            _ = self.session.cancelTask(handle);
            view.tip_handle = null;
        }
        // The window goes first, while the App, the view and the W05 owner are
        // all still whole. The host detaches the App's GPU mounts and calls
        // `on_before_close` — the one point where the swapchain, the platform
        // surface and the device may be released, because the native window
        // they present into is still alive — before it destroys that window.
        // This retires the Session window it borrowed, so the task service and
        // the models below are torn down with no window left to reach them.
        if (self.host) |application| {
            if (self.host_handle) |handle| {
                if (application.closeWindow(handle)) |closed| {
                    if (!closed) std.log.warn(
                        "menu-overlay: the host refused to close the native window",
                        .{},
                    );
                } else |err| switch (err) {
                    // A window the platform already destroyed is gone, which
                    // is the outcome the close wanted.
                    error.StaleWindow => {},
                    else => std.log.warn(
                        "menu-overlay: the native window could not be closed: {s}",
                        .{@errorName(err)},
                    ),
                }
            }
            application.deinit();
            gpa.destroy(application);
            self.host = null;
            self.host_handle = null;
        }
        self.session.shutdownTasks(100 * std.time.ns_per_ms) catch {};
        self.session.release(TipTimer, &self.timer) catch unreachable;
        self.session.release(Editor, &self.editor) catch unreachable;
        self.registry.deinit();
        self.app.deinit();
        view.release();
        gpa.destroy(view);
        gpa.destroy(self.app);
        self.session.deinit() catch unreachable;
        gpa.destroy(self.session);
        gpa.destroy(self);
    }

    /// One frame of the real App: the resize, the committed tree, and the
    /// consumer's post-publication work.
    pub fn publish(self: *Scenario, tick: u32) !*const widget.WidgetTree {
        _ = try self.app.handle(.{ .resize = .{
            .width = surface.width,
            .height = surface.height,
        } });
        const output = (try self.app.handle(.{ .frame = .{
            .tick = tick,
            .time_ms = @as(u64, tick) * 16,
        } })) orelse return error.MissingFrameOutput;
        if (output.json) |json| self.session.gpa.free(json);
        try self.view.afterFrame();
        return output.tree;
    }

    /// Drain the W05 service. It may only run between frames, never inside the
    /// App's transaction.
    pub fn drain(self: *Scenario) !usize {
        return self.session.drainTasks();
    }

    pub fn tipStats(self: *Scenario) !TipStats {
        var out: TipStats = .{};
        try self.session.read(TipTimer, self.timer, &out, TipTimer.read);
        return out;
    }

    /// The App's current committed tree, MUTABLE. `overlay.Frame.resolve`
    /// registers the clip rects it computes on the tree it is handed, so the
    /// consumer resolves against the live tree, not a copy of it.
    pub fn liveTree(self: *Scenario) !*widget.WidgetTree {
        return self.app.tree_ptr orelse error.RootNotMounted;
    }

    /// The point at the centre of a keyed widget's laid-out border box.
    pub fn centreOf(self: *Scenario, name: []const u8) ![2]f32 {
        const tree = self.app.tree_ptr orelse return error.RootNotMounted;
        const id = self.view.widget(name) orelse return error.MissingWidget;
        const node = tree.frameNode(id) orelse return error.MissingWidget;
        const rect = widget.visualBorderRect(tree, node);
        return .{ rect.x + rect.w / 2, rect.y + rect.h / 2 };
    }

    /// A real routed press. The App presses, captures and focuses on its own.
    pub fn press(self: *Scenario, point: [2]f32) !void {
        _ = try self.app.handle(.{ .mouse_down = .{ .x = point[0], .y = point[1] } });
        try self.view.afterInput();
    }

    /// A real routed release at the same point.
    pub fn lift(self: *Scenario, point: [2]f32) !void {
        _ = try self.app.handle(.{ .mouse_up = .{ .x = point[0], .y = point[1] } });
        try self.view.afterInput();
    }

    /// A real routed move. `pressed` is the driver's button state, not a
    /// convenience flag: a hover reports no button, a drag reports one.
    pub fn move(self: *Scenario, point: [2]f32, pressed: bool) !void {
        _ = try self.app.handle(.{ .mouse_move = .{
            .x = point[0],
            .y = point[1],
            .buttons = .{ .left = pressed },
        } });
        try self.view.afterInput();
    }

    /// A real routed click: press and release at one point. The App's own path
    /// decides whether that is an activation.
    pub fn click(self: *Scenario, point: [2]f32) !void {
        try self.press(point);
        try self.lift(point);
    }

    /// `steps` routed moves from `from` to `to`, inclusive of the endpoint.
    pub fn glide(self: *Scenario, from: [2]f32, to: [2]f32, steps: usize) !void {
        for (1..steps + 1) |step| {
            const t = @as(f32, @floatFromInt(step)) / @as(f32, @floatFromInt(steps));
            try self.move(.{
                from[0] + (to[0] - from[0]) * t,
                from[1] + (to[1] - from[1]) * t,
            }, true);
        }
    }

    /// A real routed drag: press, move across the threshold, release over the
    /// target.
    pub fn drag(self: *Scenario, from: [2]f32, to: [2]f32, steps: usize) !void {
        try self.press(from);
        try self.glide(from, to, steps);
        try self.lift(to);
    }

    /// The windowless raster of the committed tree. The engine's paint
    /// collector still walks LAYOUT boxes, so this applies the frame's own
    /// offset and order key per node — the same arithmetic a painter needs
    /// until the placement is folded into the committed geometry itself. It is
    /// a CPU walk of the tree the App published, not a rendered frame.
    pub fn raster(self: *Scenario) [raster_rows][raster_columns]u8 {
        var out: [raster_rows][raster_columns]u8 = @splat(@splat('.'));
        const tree = self.app.tree_ptr orelse return out;
        const view = self.view;

        var glyphs: [8]Glyph = undefined;
        var glyph_count: usize = 0;
        for (glyph_names) |entry| {
            if (view.widget(entry.key)) |id| {
                if (glyph_count < glyphs.len) {
                    glyphs[glyph_count] = .{ .id = id, .glyph = entry.glyph };
                    glyph_count += 1;
                }
            }
        }

        var stamps: [64]Stamp = undefined;
        var count: usize = 0;
        // The tree stores children first and a node paints before its
        // children, so the paint order is reverse post-order. A placed subtree
        // carries a band above the application maximum, so its emitted layer
        // already outranks every unplaced one; the walk index only breaks ties
        // INSIDE one layer, which is the same tie the painter's sort uses.
        var index = tree.nodes.items.len;
        while (index > 0) {
            index -= 1;
            if (count >= stamps.len) break;
            const node = tree.nodes.items[index];
            if (!widget.isVisible(tree, node.id)) continue;
            const id = node.widget_id orelse continue;
            var glyph: u8 = 0;
            var named = false;
            for (glyphs[0..glyph_count]) |entry| {
                if (entry.id.eql(id)) {
                    glyph = entry.glyph;
                    named = true;
                    break;
                }
            }
            if (!named) continue;
            // The tree's own border box IS the placed box, so this raster
            // reads the same geometry the painter and the router read.
            const rect = widget.visualBorderRect(tree, node.id);
            // The key is the layer the painter emits for this node, read
            // through the same `widget.effectiveLayer` the scene sorts by.
            const emitted = widget.effectiveLayer(&node, 0) catch continue;
            const order: u64 = (@as(u64, emitted) << 32) |
                @as(u64, @intCast(tree.nodes.items.len - 1 - index));
            if (rect.w <= 0 or rect.h <= 0) continue;
            stamps[count] = .{ .rect = rect, .order = order, .glyph = glyph };
            count += 1;
        }

        for (0..raster_rows) |row| {
            for (0..raster_columns) |column| {
                const x = (@as(f32, @floatFromInt(column)) + 0.5) * surface.width /
                    @as(f32, @floatFromInt(raster_columns));
                const y = (@as(f32, @floatFromInt(row)) + 0.5) * surface.height /
                    @as(f32, @floatFromInt(raster_rows));
                var best: ?Stamp = null;
                for (stamps[0..count]) |stamp| {
                    if (x < stamp.rect.x or x >= stamp.rect.x + stamp.rect.w) continue;
                    if (y < stamp.rect.y or y >= stamp.rect.y + stamp.rect.h) continue;
                    if (best == null or stamp.order > best.?.order) best = stamp;
                }
                if (best) |stamp| out[row][column] = stamp.glyph;
            }
        }
        return out;
    }

    /// Compare the base tree walk with the paint-priority routing answer.
    /// Placement gives both walks the same geometry, but only the overlay
    /// frame ranks overlapping content above the underlying controls.
    /// The run prints both answers to make that distinction visible.
    pub fn picksAt(self: *Scenario, point: [2]f32) struct { raw: u8, placed: u8 } {
        const tree = self.app.tree_ptr orelse return .{ .raw = '.', .placed = '.' };
        const view = self.view;
        var raw: u8 = '.';
        if (input.hitTest(tree, point)) |node| {
            if (stableAncestor(tree, node)) |id| {
                if (glyphOf(view, id)) |glyph| raw = glyph;
            }
        }
        var placed: u8 = '.';
        if (view.frame.hitTestTotal(tree, point)) |node| {
            if (stableAncestor(tree, node)) |id| {
                if (glyphOf(view, id)) |glyph| placed = glyph;
            }
        }
        return .{ .raw = raw, .placed = placed };
    }
};

fn report(verbose: bool, comptime format: []const u8, args: anytype) void {
    if (!verbose) return;
    std.debug.print(format, args);
}

/// The specimen. `main` runs it with printing; the test runs the SAME function
/// silently and then asserts the model it left behind, so the evidence and the
/// test can never drift apart.
pub fn specimen(self: *Scenario, verbose: bool) !void {
    const app = self.app;
    const view = self.view;

    _ = try self.publish(1);
    report(verbose, "frame 1: committed, routed events so far = {d}\n", .{view.routed});

    // ── a real routed click opens the menu ──
    try self.click(try self.centreOf(key_file));
    report(verbose, "file click: clicks={d} open_menu={}\n", .{
        view.file_clicks, view.open_menu,
    });
    _ = try self.publish(2);
    const menu_id = view.widget(key_menu).?;
    const menu = view.frame.placement(self.app.tree_ptr.?, menu_id) orelse return error.UnplacedMenu;
    const open_menu_node = (try self.liveTree()).frameNode(menu_id) orelse return error.MissingMenu;
    view.menu_placement = menu.rect;
    // Window escape imposes no clip of its own. That is the tree's one rule:
    // the menu's own ancestry still applies, and no placement clip was written.
    const imposed = self.app.tree_ptr.?.node(open_menu_node).?.placement_clip;
    view.menu_escaped_clip = imposed == null;
    report(verbose, "menu placement {d:.0},{d:.0} {d:.0}x{d:.0} order={d} escaped={}\n", .{
        menu.rect.x, menu.rect.y,            menu.rect.w, menu.rect.h,
        menu.order,  view.menu_escaped_clip,
    });
    report(verbose, "focus moved into the menu: {any}\n", .{view.focus_after_open});

    // ── a real routed wheel scrolls the anchor, and the popup follows ──
    const anchor = try self.centreOf(key_anchor);
    _ = try app.handle(.{ .mouse_wheel = .{
        .x = anchor[0],
        .y = anchor[1],
        .delta_x = 0,
        .delta_y = -1,
        .unit = .line,
    } });
    _ = try self.publish(3);
    const scrolled = view.frame.placement(self.app.tree_ptr.?, view.widget(key_menu).?) orelse
        return error.UnplacedMenu;
    view.scroll_offset = view.scroll.offset[1];
    view.scrolled_by = scrolled.rect.y - menu.rect.y;
    report(verbose, "wheel: scroll={d:.0} menu y {d:.0} -> {d:.0} (moved {d:.0})\n", .{
        view.scroll_offset, menu.rect.y, scrolled.rect.y, view.scrolled_by,
    });

    // ── a real routed hover arms a W05 timer, and only W05 shows it ──
    self.ticks.value = 1_000;
    try self.move(try self.centreOf(key_hint), false);
    view.tip_deadline_ns = view.tip.deadline().?.at_ns;
    view.service_deadline_ns = (try self.session.nextTaskDeadline()) orelse
        return error.MissingServiceDeadline;
    report(verbose, "hover hint: tooltip deadline={d} service deadline={d} arms={d} cancels={d}\n", .{
        view.tip_deadline_ns, view.service_deadline_ns, view.tip_arms, view.tip_cancels,
    });
    // One nanosecond short: the job is pending and nothing is visible.
    self.ticks.value = view.tip_deadline_ns - 1;
    _ = try self.drain();
    view.tip_pending_early = (try self.tipStats()).delivered == 0 and !view.tip.visible();
    // At the deadline: the W05 handler runs, and the model publishes it.
    self.ticks.value = view.tip_deadline_ns;
    _ = try self.drain();
    view.tip_at_show = try self.tipStats();
    view.arms_at_show = view.tip_arms;
    report(verbose, "W05 delivery: delivered={d} fired={d} visible={}\n", .{
        view.tip_at_show.delivered, view.tip_at_show.fired, view.tip_at_show.visible,
    });
    _ = try self.publish(4);

    // ── paint order and hit precedence come from one key ──
    const tip_tree = try self.liveTree();
    const menu_content = view.widget(key_menu).?;
    const tip_content = view.widget(key_tip).?;
    const menu_node = tip_tree.frameNode(menu_content) orelse return error.MissingMenu;
    const tip_node = tip_tree.frameNode(tip_content) orelse return error.MissingTip;
    const menu_paint = tip_tree.nodeConst(menu_node) orelse return error.MissingMenuPaint;
    const tip_paint = tip_tree.nodeConst(tip_node) orelse return error.MissingTipPaint;
    // The layers the PAINTER emits, read through the same function the scene
    // sorts by, beside the highest layer any application node authors. A band
    // starts above that maximum, so this compares the engine's own numbers
    // and never a constant this file chose.
    const menu_layer = try widget.effectiveLayer(menu_paint, 0);
    const tip_layer = try widget.effectiveLayer(tip_paint, 0);
    const app_max = try widget.maximumPaintLayer(tip_tree);
    view.tip_paints_above = tip_layer > menu_layer and menu_layer > app_max;
    const menu_placement = view.frame.placement(tip_tree, menu_content).?;
    const tip_placement = view.frame.placement(tip_tree, tip_content).?;
    if (overlapRect(menu_placement.rect, tip_placement.rect)) |shared| {
        const point: [2]f32 = .{
            shared.x + shared.w / 2,
            shared.y + shared.h / 2,
        };
        view.overlap_point = point;
        const hit = view.frame.hitTest(tip_tree, point) orelse return error.MissedOverlay;
        view.overlap_winner = if (withinSubtree(tip_tree, hit, tip_node)) 'T' else 'M';
    }
    report(verbose, "paint order: menu key {d} layer {d}, tooltip key {d} layer {d}, app max {d}; overlap winner {c}\n", .{
        menu_placement.order, menu_layer, tip_placement.order, tip_layer, app_max,
        view.overlap_winner,
    });
    report(verbose, "hoverable bounds published: {}\n", .{view.tip_bounds_set});

    // ── the keyboard returns focus to the surviving prior target ──
    _ = try app.handle(.{ .key_down = .{ .key = .escape } });
    view.focus_after_escape = app.focus_manager.current;
    report(verbose, "escape: menu open={} closes={d} focus restores={d} focus={any}\n", .{
        view.open_menu, view.menu_closes, view.focus_restores, view.focus_after_escape,
    });
    // A real pointer leave retires the hoverable tooltip before the drag targets.
    _ = try app.handle(.mouse_leave);
    try view.afterInput();
    _ = try self.publish(5);

    // ── a drag cancelled by leaving the window never reaches a drop ──
    const card_point = try self.centreOf(key_card);
    const drop_point = try self.centreOf(key_drop);
    // Each drag is read as its own difference from the instant before it, so
    // one drag's cancellation is never charged to the next one.
    const outside_base = view.dragSnapshot();
    try self.press(card_point);
    // A move under the threshold is not a drag yet.
    try self.move(.{ card_point[0] + 1, card_point[1] }, true);
    if (view.drag_enters == 0) view.under_threshold_moves += 1;
    try self.glide(card_point, drop_point, 2);
    report(verbose, "drag: enters={d} moves={d}, target reached\n", .{
        view.drag_enters, view.drag_moves,
    });
    // The pointer leaves the window: the engine revokes the capture and blurs.
    _ = try app.handle(.window_focus_lost);
    view.outside_cancel = view.dragSnapshot().since(outside_base);
    report(verbose, "window focus lost: outside={d} cancels={d} drops={d} frees={d} focus={any}\n", .{
        view.outside_cancels,      view.outside_cancel.cancels, view.outside_cancel.drops,
        view.outside_cancel.frees, app.focus_manager.current,
    });
    _ = try self.publish(6);

    // ── a real routed drag that a refusing target rejects ──
    view.accept_drops = false;
    const refused_base = view.dragSnapshot();
    try self.drag(card_point, drop_point, 2);
    view.refused = view.dragSnapshot().since(refused_base);
    report(verbose, "refused drop: checks={d} cancels={d} drops={d} frees={d} card clicks={d}\n", .{
        view.refused.checks, view.refused.cancels,     view.refused.drops,
        view.refused.frees,  view.refused.card_clicks,
    });
    _ = try self.publish(7);

    // ── and one that it accepts ──
    view.accept_drops = true;
    const accepted_base = view.dragSnapshot();
    try self.drag(card_point, drop_point, 2);
    view.accepted = view.dragSnapshot().since(accepted_base);
    report(verbose, "accepted drop: drops={d} title='{s}' frees={d} foreign reads={d}\n", .{
        view.accepted.drops,         view.droppedTitle(), view.accepted.frees,
        view.accepted.foreign_reads,
    });
    _ = try self.publish(8);

    // ── leaving and re-entering respects the delay, and a retired owner
    //    takes its pending W05 timer with it ──
    const before_leave = try self.tipStats();
    try self.move(.{ surface.width * 0.5, surface.height - 1 }, false);
    const after_leave = try self.tipStats();
    // Remove the dismissed tooltip from hit testing before returning to its owner.
    _ = try self.publish(9);
    self.ticks.value = 5_000;
    try self.move(try self.centreOf(key_hint), false);
    view.reenter_deadline_ns = view.tip.deadline().?.at_ns;
    view.arms_at_reenter = view.tip_arms;
    view.cancels_at_reenter = view.tip_cancels;
    _ = try self.drain();
    const before_retire = try self.tipStats();
    view.show_hint = false;
    _ = try self.publish(10);
    self.ticks.value = view.reenter_deadline_ns + 1;
    _ = try self.drain();
    const after_retire = try self.tipStats();
    view.retire_deliveries = after_retire.delivered - before_retire.delivered;
    view.retire_visible = view.tip.visible();
    report(verbose, "re-enter: first deadline={d}, re-armed at={d} arms={d} cancels={d}\n", .{
        view.tip_deadline_ns, view.reenter_deadline_ns, view.tip_arms, view.tip_cancels,
    });
    report(verbose, "retired owner: deliveries after={d} visible={} (leave moved none: {})\n", .{
        view.retire_deliveries,                          view.tip.visible(),
        after_leave.delivered == before_leave.delivered,
    });

    // ── last, the menu item is reached at its PAINTED position ──
    // Reopen so the overlay is placed again, then aim at the item's own box
    // inside the placed menu rather than at the container's centre.
    try self.click(try self.centreOf(key_file));
    _ = try self.publish(10);
    const placed_menu = view.frame.placement(self.app.tree_ptr.?, view.widget(key_menu).?) orelse
        return error.UnplacedMenu;
    const item_point: [2]f32 = .{
        placed_menu.rect.x + placed_menu.rect.w / 2,
        placed_menu.rect.y + 10,
    };
    const picks = self.picksAt(item_point);
    view.raw_pick_glyph = picks.raw;
    view.placed_pick_glyph = picks.placed;
    report(verbose, "item at {d:.0},{d:.0}: raw layout-box pick '{c}', placed pick '{c}'\n", .{
        item_point[0], item_point[1], picks.raw, picks.placed,
    });
    try self.click(item_point);
    report(verbose, "item clicks={d} menu open={} closes={d} focus restores={d} card clicks={d}\n", .{
        view.item_clicks, view.open_menu, view.menu_closes, view.focus_restores, view.card_clicks,
    });
    _ = try self.publish(11);

    // ── a closing frame with BOTH overlays placed ──
    // The run prints a raster of the committed tree, so the scene ends in the
    // state worth looking at: the menu open and the tooltip shown, each placed
    // over the content it covers.
    view.show_hint = true;
    // The hint was retired above, so it has to exist in a committed frame
    // before the pointer can hover it.
    _ = try self.publish(12);
    self.ticks.value = view.reenter_deadline_ns + 2;
    try self.move(try self.centreOf(key_hint), false);
    // A hover arms a deadline; only reaching it lets the W05 handler show it.
    self.ticks.value = view.tip.deadline().?.at_ns;
    _ = try self.drain();
    try self.click(try self.centreOf(key_file));
    _ = try self.publish(13);
    report(verbose, "closing frame: menu open={} tooltip visible={} tip shows={d}\n", .{
        view.open_menu, view.tip.visible(), view.tip_shows,
    });

    // ── the native menu bridge resolves enablement from the focus context ──
    const bar: menus.MenuBar = .{ .menus = &.{
        .{ .title = "Edit", .items = &.{
            .{ .id = 1, .label = "Undo", .kind = .action, .action_name = "edit.undo" },
            .{ .id = 2, .label = "Redo", .kind = .action, .action_name = "edit.redo" },
        } },
    } };
    var bridge = menus.MenuActionBridge.init(&self.registry);
    const focus_tree = self.app.tree_ptr.?;
    const focused = app.focus_manager.current orelse return error.MissingFocus;
    _ = try self.registry.bind(
        UndoAction,
        Editor,
        Editor.undo,
        Editor.undoAvailable,
        .{ .widget = view.widget(key_file).? },
        self.editor.weak(),
    );
    _ = try self.registry.bind(
        RedoAction,
        Editor,
        Editor.redo,
        Editor.redoAvailable,
        .{ .widget = view.widget(key_file).? },
        self.editor.weak(),
    );
    var evaluated = try bridge.evaluate(self.gpa, bar, focus_tree, focused);
    defer evaluated.deinit();
    report(verbose, "menu bridge on the live focus: undo enabled={any} redo enabled={any}\n", .{
        evaluated.menus[0].items[0].enabled,
        evaluated.menus[0].items[1].enabled,
    });
    report(verbose, "native global menu on this host: {any}\n", .{menus.hasNativeGlobalMenu()});
}

// ── the `--native` arm ─────────────────────────────────────────────────────
//
// One real toplevel, the same Session/App/MenuView, and the same step list
// the headless `specimen` walks. What differs is everything between the
// consumer and the screen: a host window, a device, a swapchain, and input
// that arrives through SDL's queue and this host's own dispatch instead of
// being written straight into the App.

/// A loaded SPIR-V module: the bytes, and the u32 view the GPU wants. The
/// words borrow the bytes, so the file outlives the shader objects made from
/// them — although `NativeFrame.init` copies them, so only `init` needs them.
const ShaderFile = struct {
    bytes: []u8,
    words: []const u32,

    fn load(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !ShaderFile {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
        errdefer gpa.free(bytes);
        if (bytes.len == 0 or bytes.len % @sizeOf(u32) != 0) return error.InvalidShaderBytes;
        return .{ .bytes = bytes, .words = @alignCast(std.mem.bytesAsSlice(u32, bytes)) };
    }

    fn deinit(self: *ShaderFile, gpa: std.mem.Allocator) void {
        gpa.free(self.bytes);
        self.* = undefined;
    }
};

/// The bounded step list. These names are the controller protocol: each one
/// is a step of the sequence, each asserts its own clause before it reports,
/// and an unknown name is refused before a window is ever opened. The order
/// is the declaration order, so `names[i]` is `@enumFromInt(i)`.
pub const Step = enum {
    frame,
    open,
    scroll,
    hover,
    tip_due,
    order,
    escape,
    threshold,
    capture_lost,
    refuse,
    accept,
    tip_leave,
    tip_remove,
    reopen,
    closing,

    pub const names = [_][]const u8{
        "frame",
        "open",
        "scroll",
        "hover",
        "tip-due",
        "order",
        "escape",
        "threshold",
        "capture-lost",
        "refuse",
        "accept",
        "tip-leave",
        "tip-remove",
        "reopen",
        "closing",
    };

    pub fn parse(text: []const u8) ?Step {
        for (names, 0..) |name, index| {
            if (std.mem.eql(u8, name, text)) return @fromBackingInt(@intCast(index));
        }
        return null;
    }
};

/// The command line. Flags only, so `zig build run-parity-menu-overlay` with
/// no arguments is still the headless proof, and every path `--native` reads
/// has a repo-relative default. Every string here is owned by the caller's
/// allocator, defaults included, so `deinit` frees all of them.
pub const Options = struct {
    native: bool = false,
    /// Run the sequence through this step and stop.
    only: ?[]const u8 = null,
    /// Take the step names from stdin instead of walking the list.
    controller: bool = false,
    capture: ?[]const u8 = null,
    capture_step: []const u8,
    /// Sentinel-terminated, because `window_contract.WindowOptions.title` is
    /// `[:0]const u8` and `Native` hands this value straight to it. It is
    /// owned here for the whole run and released by `deinit`.
    title: [:0]const u8,
    quad_vert: []const u8,
    quad_frag: []const u8,
    sort_comp: []const u8,
    fullscreen_vert: []const u8,
    blit_oklab: []const u8,

    /// Fill every field, defaults included, so `deinit` owns all of them from
    /// the first statement: an allocation failure part-way through leaves a
    /// value `deinit` can still release.
    fn defaults(self: *Options, gpa: std.mem.Allocator) !void {
        self.* = .{
            .capture_step = "",
            .title = "",
            .quad_vert = "",
            .quad_frag = "",
            .sort_comp = "",
            .fullscreen_vert = "",
            .blit_oklab = "",
        };
        // From here every allocation is owned, so a failure part-way through
        // unwinds through `deinit`: the fields already filled are freed in
        // the shape they were allocated, and the ones still holding the
        // never-filled empty sentinel own nothing.
        errdefer self.deinit(gpa);
        // The title is allocated apart, because it is the one field whose
        // declared type is a SENTINEL slice and so cannot share the plain
        // slice path below.
        self.title = try gpa.dupeSentinel(u8, native_title, 0);
        const fields = [_]*[]const u8{
            &self.capture_step,
            &self.quad_vert,
            &self.quad_frag,
            &self.sort_comp,
            &self.fullscreen_vert,
            &self.blit_oklab,
        };
        const paths = [_][]const u8{
            "closing",
            default_quad_vert,
            default_quad_frag,
            default_sort_comp,
            default_fullscreen_vert,
            default_blit_oklab,
        };
        for (fields, paths) |field, text| {
            field.* = try gpa.dupe(u8, text);
        }
    }

    fn deinit(self: *Options, gpa: std.mem.Allocator) void {
        if (self.capture) |path| gpa.free(path);
        if (self.only) |name| gpa.free(name);
        release(gpa, self.capture_step);
        // Freed with its SENTINEL TYPE, which `Allocator.free` turns back
        // into the n+1 bytes `dupeSentinel` took. A filled title is never empty —
        // `parseArgs` refuses `--title ""` — so an empty one is the
        // never-filled sentinel of `defaults` and owns nothing.
        if (self.title.len != 0) gpa.free(self.title);
        release(gpa, self.quad_vert);
        release(gpa, self.quad_frag);
        release(gpa, self.sort_comp);
        release(gpa, self.fullscreen_vert);
        release(gpa, self.blit_oklab);
        self.* = undefined;
    }
};

/// Replace one owned string with a fresh copy of `text`. The old value is held
/// in its DECLARED type, so the terminator a sentinel-typed field carries
/// reaches `free` intact; the field is overwritten only once the new copy
/// exists; and the old allocation is then freed exactly once. A failed dupe
/// leaves the field owning exactly what it owned, which is what the caller's
/// errdefer releases. The branch is comptime — each field is allocated the way
/// it is declared — and there is still exactly one copy per field.
fn replace(gpa: std.mem.Allocator, field: anytype, text: []const u8) !void {
    const old = field.*;
    if (comptime std.meta.sentinel(@TypeOf(old)) == null) {
        field.* = try gpa.dupe(u8, text);
    } else {
        field.* = try gpa.dupeSentinel(u8, text, 0);
    }
    release(gpa, old);
}

/// Release one of `Options`' owned strings, keeping whatever type it was
/// declared with. `Allocator.free` recovers a terminator with
/// `mem.absorbSentinel`, so a sentinel allocation has to reach it WITH its
/// sentinel type: erasing it here would free n bytes of an n+1 allocation.
/// A plain field that was never filled holds an empty slice, which no path
/// this file accepts ever allocates, so it is skipped rather than freed.
fn release(gpa: std.mem.Allocator, memory: anytype) void {
    if (memory.len == 0 and std.meta.sentinel(@TypeOf(memory)) == null) return;
    gpa.free(memory);
}

fn parseArgs(init: std.process.Init, gpa: std.mem.Allocator) !Options {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args.deinit();
    _ = args.next() orelse return error.MissingExecutableName;

    var options: Options = undefined;
    try options.defaults(gpa);
    errdefer options.deinit(gpa);

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--native")) {
            options.native = true;
        } else if (std.mem.eql(u8, arg, "--controller")) {
            options.controller = true;
        } else if (std.mem.eql(u8, arg, "--step")) {
            if (options.only != null) return error.RepeatedOption;
            options.only = try gpa.dupe(u8, args.next() orelse return error.MissingOptionValue);
        } else if (std.mem.eql(u8, arg, "--capture")) {
            if (options.capture != null) return error.RepeatedOption;
            options.capture = try gpa.dupe(u8, args.next() orelse return error.MissingOptionValue);
        } else if (std.mem.eql(u8, arg, "--capture-step")) {
            const value = args.next() orelse return error.MissingOptionValue;
            try replace(gpa, &options.capture_step, value);
        } else if (std.mem.eql(u8, arg, "--title")) {
            const value = args.next() orelse return error.MissingOptionValue;
            // A window with an empty name cannot be aimed at, and `deinit`
            // tells a filled title from a never-filled one by being empty.
            if (value.len == 0) return error.EmptyTitle;
            try replace(gpa, &options.title, value);
        } else if (std.mem.eql(u8, arg, "--quad-vert")) {
            try replace(gpa, &options.quad_vert, args.next() orelse return error.MissingOptionValue);
        } else if (std.mem.eql(u8, arg, "--quad-frag")) {
            try replace(gpa, &options.quad_frag, args.next() orelse return error.MissingOptionValue);
        } else if (std.mem.eql(u8, arg, "--sort-comp")) {
            try replace(gpa, &options.sort_comp, args.next() orelse return error.MissingOptionValue);
        } else if (std.mem.eql(u8, arg, "--fullscreen-vert")) {
            try replace(gpa, &options.fullscreen_vert, args.next() orelse return error.MissingOptionValue);
        } else if (std.mem.eql(u8, arg, "--blit-oklab")) {
            try replace(gpa, &options.blit_oklab, args.next() orelse return error.MissingOptionValue);
        } else return error.UnknownArgument;
    }

    // A step name is data from outside this file, so it is resolved here: an
    // unknown one is refused before SDL is started, not halfway through a run.
    if (options.only) |name| {
        if (Step.parse(name) == null) return error.UnknownStep;
    }
    if (Step.parse(options.capture_step) == null) return error.UnknownStep;
    // `--controller` and `--capture` are native-only promises. Saying so by
    // name beats opening no window and reporting success.
    if (options.controller and !options.native) return error.ControllerNeedsNative;
    if (options.capture != null and !options.native) return error.CaptureNeedsNative;
    return options;
}

/// The presented arm: one owned toplevel, the device stack that presents into
/// it, and the SDL ingress every input event this arm uses takes.
///
/// It is declared in place and never moved, because `NativeFrame` holds
/// addresses into itself, and it outlives the window's close, because the
/// host's `on_before_close` hook is what releases the device stack while the
/// native window is still alive.
pub const Native = struct {
    const Self = @This();

    gpa: std.mem.Allocator,
    io: std.Io,
    options: Options,
    scenario: *Scenario,

    application: *host.Application,
    handle: window_contract.WindowHandle,
    managed: *host.ManagedWindow,
    native_id: sdl3.video.WindowId,
    /// The X11 window the platform really created, read out of SDL's own
    /// property store. An X client aims at THIS identifier: SDL's own window
    /// id is a handle into this process and means nothing outside it. A
    /// backend that publishes none has no such identifier, and every request
    /// is refused by name rather than aimed at a number nobody can use.
    x11_window: ?i64,
    driver: [:0]const u8,

    loader: frame_mod.SystemVulkanLoader,
    gpu: noapi.Gpu,
    /// The platform surface made from the SDL window and adopted. It owns the
    /// `VkSurfaceKHR` on the way out, so no SDL wrapper is kept beside it.
    surface: noapi.Surface,
    adapter: NativeFrame,
    /// The recording the next frame opens. Caller-owned storage that must not
    /// move for as long as the adapter holds it.
    recording: NativeFrame.Frame,
    /// The five modules this arm records with, held until the device stack
    /// goes. `NativeFrame.init` copies their words, so nothing reads these
    /// again — they exist so the bytes have an owner with a teardown.
    shaders: [5]ShaderFile = undefined,
    shaders_live: bool = false,
    loader_live: bool = false,
    gpu_live: bool = false,
    surface_live: bool = false,
    adapter_live: bool = false,
    device_dead: bool = false,

    /// App frames this arm committed AND presented, and the swapchain
    /// acquires that were out of date on the way.
    tick: u32 = 0,
    frames: u32 = 0,
    retries: u32 = 0,
    /// The window this arm opened is gone — a platform close reached it before
    /// this arm's own teardown did.
    window_dead: bool = false,

    // ── the last presented frame, read back out of its own Oklab target ──
    pixels: []const f32 = &.{},
    extent: noapi.Extent2D = .{ .width = 0, .height = 0 },
    /// What the App laid that frame out in, so a probe maps a logical rect
    /// onto the device pixels the window really has.
    logical: WindowSize = .{ .width = 0, .height = 0 },
    /// The menu's placement before and after the scroll, so the step that
    /// scrolls reports the delta it read out of the committed tree.
    menu_before_scroll: widget.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    menu_after_scroll: widget.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    first_deadline_ns: i96 = 0,
    reenter_deadline_ns: i96 = 0,
    /// The drag counters read at the instant before each drag, so a step
    /// names its own drag instead of the run's total.
    drag_base: DragSnapshot = .{},
    /// Claims this run has checked and found true, and the first one that was
    /// not. The count is what the closing line reports, so "no oracles ran"
    /// can never be mistaken for "every oracle held".
    claims: u32 = 0,
    failed: ?anyerror = null,
    report: [2048]u8 = undefined,

    pub fn init(self: *Self, gpa: std.mem.Allocator, io: std.Io, scenario: *Scenario, options: Options) !void {
        self.* = .{
            .gpa = gpa,
            .io = io,
            .options = options,
            .scenario = scenario,
            .application = undefined,
            .handle = undefined,
            .managed = undefined,
            .native_id = 0,
            .x11_window = null,
            .driver = "<null>",
            .loader = undefined,
            .gpu = undefined,
            .surface = undefined,
            .adapter = undefined,
            .recording = undefined,
            .shaders = undefined,
        };
        // No `video_driver`: this arm needs the platform's own driver, because
        // a Vulkan surface cannot be made for the hidden window the dummy
        // driver keeps. The headless arm never reaches any of this.
        self.application = try gpa.create(host.Application);
        errdefer gpa.destroy(self.application);
        self.application.* = try host.Application.init(gpa, scenario.session, .{
            .app_id = native_app_id,
        });
        errdefer self.application.deinit();
        self.driver = sdl3.video.getCurrentDriverName() orelse "<null>";
        // The host owns the frame clock, the input path and the close. Every
        // one of those three hooks is this arm, on storage that outlives the
        // window.
        self.application.setHooks(.{
            .context = self,
            .on_frame = onFrame,
            .on_event = onEvent,
            .on_before_close = onBeforeClose,
            .on_closed = onClosed,
        });
        self.handle = try self.application.openWindowWithApp(scenario.app, .{
            .title = self.options.title,
            .width = native_width,
            .height = native_height,
            .resizable = false,
            .visible = true,
            .gpu_surface = true,
        });
        // From here the scenario owns the window and the host: its `deinit`
        // closes the window — which runs `on_before_close`, so the device
        // stack goes while the native window is still alive — and then drops
        // the host. A failure anywhere below still tears down in that order.
        scenario.host = self.application;
        scenario.host_handle = self.handle;
        self.managed = try self.application.getWindow(self.handle);
        self.native_id = self.managed.native.id;
        self.x11_window = if (self.managed.native.sdl.getProperties()) |properties|
            properties.x11_window
        else |_|
            null;

        // The frame module's own loader, the same one the windowless parity
        // proof builds its device from, so both halves of this run resolve
        // their entry points the same way. It stays open until the device made
        // from it is gone.
        self.loader = try frame_mod.SystemVulkanLoader.open();
        self.loader_live = true;
        errdefer self.releaseDevice();
        self.gpu = try noapi.Gpu.init(.{
            // Three, not two: the renderer rings its per-frame paint buffers
            // over three slots, one per in-flight frame.
            .frames_in_flight = frame_mod.scene.frames_in_flight,
            .app_name = "nogui-menu-overlay",
            .validation = false,
            .loader = self.loader.options(),
            .io = io,
            .allocator = gpa,
        });
        self.gpu_live = true;
        // SDL's own Vulkan subsystem, for the platform surface call and
        // nothing else: on Wayland `SDL_Vulkan_CreateSurface` refuses with
        // "Vulkan is not loaded" unless this has run.
        try sdl3.vulkan.loadLibrary(null);
        self.surface = try noapi.Surface.initSdl(
            &self.gpu,
            @ptrCast(self.managed.native.sdl.value),
            @ptrCast(&sdl3.c.SDL_Vulkan_CreateSurface),
            .{ .extent = try self.deviceExtent() },
        );
        self.surface_live = true;
        // The five SPIR-V modules, loaded into storage this struct owns.
        // `NativeFrame.init` copies the words into shader objects, so these
        // only have to outlive this call — and they are released with the
        // rest of the device stack.
        var quad_vert = try ShaderFile.load(gpa, io, self.options.quad_vert);
        errdefer quad_vert.deinit(gpa);
        var quad_frag = try ShaderFile.load(gpa, io, self.options.quad_frag);
        errdefer quad_frag.deinit(gpa);
        var sort_comp = try ShaderFile.load(gpa, io, self.options.sort_comp);
        errdefer sort_comp.deinit(gpa);
        var fullscreen_vert = try ShaderFile.load(gpa, io, self.options.fullscreen_vert);
        errdefer fullscreen_vert.deinit(gpa);
        var blit_oklab = try ShaderFile.load(gpa, io, self.options.blit_oklab);
        errdefer blit_oklab.deinit(gpa);
        try self.adapter.init(.{
            .allocator = gpa,
            .gpu = &self.gpu,
            .fonts = &.{.{ .family = "InterVariable", .bytes = font_bytes }},
            .shaders = .{
                .quad_vert = quad_vert.words,
                .quad_frag = quad_frag.words,
                .sort_comp = sort_comp.words,
                .fullscreen_vert = fullscreen_vert.words,
                .blit_oklab = blit_oklab.words,
            },
            .name = "nogui_menu_overlay_blit_oklab",
        });
        self.adapter_live = true;
        // The bytes now belong to this struct, which frees them exactly once
        // in `releaseDevice`. Each local is EMPTIED in the same statement:
        // `Allocator.free` of a zero-length slice returns before touching the
        // allocator, so the errdefers above become no-ops instead of a second
        // free of the same allocation.
        self.shaders = .{
            quad_vert,
            quad_frag,
            sort_comp,
            fullscreen_vert,
            blit_oklab,
        };
        self.shaders_live = true;
        for ([_]*ShaderFile{ &quad_vert, &quad_frag, &sort_comp, &fullscreen_vert, &blit_oklab }) |local| {
            local.* = .{ .bytes = &.{}, .words = &.{} };
        }
        // The App measures through this adapter's own text engine and records
        // through its endpoint: one measure source and one endpoint, mounted
        // before the first frame so no frame is committed without them.
        scenario.app.measure = self.adapter.measurer();
        try scenario.app.attachGpu(self.adapter.gpuEndpoint());
    }

    /// Release the device stack, once. The host has already detached the App
    /// from the endpoint by the time `on_before_close` runs, and the surface
    /// references the native window, so this may only happen while that
    /// window is alive — which is exactly when the host calls it.
    fn releaseDevice(self: *Self) void {
        if (self.device_dead) return;
        self.device_dead = true;
        if (self.adapter_live) {
            self.adapter_live = false;
            self.adapter.deinit();
        }
        if (self.surface_live) {
            self.surface_live = false;
            self.surface.deinit();
        }
        if (self.gpu_live) {
            self.gpu_live = false;
            self.gpu.deinit();
        }
        if (self.loader_live) {
            self.loader_live = false;
            self.loader.close();
        }
        // The SPIR-V bytes outlive the shaders only while this struct does,
        // so they are released with the device that read them.
        if (self.shaders_live) {
            self.shaders_live = false;
            for (&self.shaders) |*module| module.deinit(self.gpa);
        }
    }

    // There is deliberately no `deinit` here. The device stack is released by
    // `on_before_close`, which the host runs while the native window is still
    // alive — the only order the platform allows, since the swapchain and the
    // `VkSurfaceKHR` both reference that window. A caller that reached the
    // device any earlier would destroy a surface the window still presents
    // into; `init`'s own errdefer covers the one case where no window exists.

    // ── the host's hooks: the frame, the input, and both closes ────────

    fn onFrame(
        raw: *anyopaque,
        _: *host.Application,
        managed: *host.ManagedWindow,
        _: nogui.frame_demand.FrameDemand.Work,
    ) anyerror!bool {
        const self: *Self = @ptrCast(@alignCast(raw));
        return self.drawFrame(managed);
    }

    /// Input arrives through the platform and leaves through the host's own
    /// dispatch. This arm pushes nothing into SDL: every event it needs is
    /// REQUESTED of an external controller and delivered by the platform.
    ///
    /// The host routes NOTHING to the App on its own. `Application.dispatch`
    /// translates one SDL event into one `Window.Event`, hands THAT to
    /// `on_event` exactly once, and returns — its own contract says no input
    /// reaches the App until the caller or this hook consumes it, and
    /// `routeWindow` has no App call in it. So this hook is the ONLY route
    /// into the App, which is why every arm below forwards its event and why
    /// none of them may be dropped: a second route here would deliver one
    /// platform event to the App twice, and no arm may exist that delivers it
    /// a second time.
    ///
    /// `afterInput` runs once, after the forward and before the next frame,
    /// which is the only point where the W05 tooltip deadline may be rearmed
    /// or cancelled. A window event the platform translated into nothing
    /// returns above and leaves that state alone.
    fn onEvent(raw: *anyopaque, _: *host.Application, delivered: host.Application.Event) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(raw));
        switch (delivered) {
            .window => |routed| {
                const translated = routed.translated orelse return;
                const app = self.scenario.app;
                switch (translated) {
                    .input => |value| _ = try app.handle(value),
                    // The platform's own repeat flag decides whether this is a
                    // SECOND press of a held key or the one press a request
                    // asked for. X11 auto-repeat delivers the same key down
                    // again, and this arm must not turn one Escape into a
                    // second close — the flag is forwarded to the App with the
                    // event, so dropping it here is what loses it.
                    .key_down => |value| {
                        if (value.repeat) return;
                        _ = try app.handle(value.core);
                    },
                    .resize => |value| _ = try app.handle(value.core),
                    // A close request from the platform is not this arm's
                    // decision to make; the run's own teardown closes the
                    // window, in the order the surface needs.
                    .close => return,
                }
                try self.scenario.view.afterInput();
            },
            else => {},
        }
    }

    fn onBeforeClose(raw: *anyopaque, _: *host.ManagedWindow) void {
        const self: *Self = @ptrCast(@alignCast(raw));
        self.releaseDevice();
    }

    fn onClosed(raw: *anyopaque, _: window_contract.WindowHandle) void {
        const self: *Self = @ptrCast(@alignCast(raw));
        self.window_dead = true;
    }

    // ── one presented frame ────────────────────────────────────────────

    /// The window's own pixel extent, read from the platform rather than
    /// assumed. The driver may clamp the image it hands back, and both
    /// passes size themselves to that image instead.
    fn deviceExtent(self: *Self) !noapi.Extent2D {
        const pixels = try self.managed.native.pixelExtent();
        return .{ .width = pixels.width, .height = pixels.height };
    }

    /// One frame of the real App over this window: the host's callback builds
    /// and lays the frame out, the consumer's per-frame work runs against the
    /// tree it published, and the SAME event records the tree into this
    /// window's swapchain image. The readback that follows is out of the
    /// Oklab target those passes wrote.
    fn drawFrame(self: *Self, managed: *host.ManagedWindow) !bool {
        const scenario = self.scenario;
        const observed = managed.observed;
        const logical: WindowSize = .{
            .width = @floatFromInt(observed.size.width),
            .height = @floatFromInt(observed.size.height),
        };
        if (!try self.beginFrame(.{
            .logical = logical,
            .device = try self.deviceExtent(),
            .scale = try observed.pixelScale(),
        })) return false;
        errdefer self.cancelRecording();

        self.tick += 1;
        const output = try scenario.app.frameWithGpuAtTime(
            self.tick,
            @as(u64, self.tick) * 16,
            .{ .width = logical.width, .height = logical.height },
            &self.recording.gpu_frame,
        );
        if (output.json) |json| scenario.session.gpa.free(json);
        try scenario.view.afterFrame();

        var painted = try self.adapter.buildScene(.{}, &output);
        defer painted.deinit();
        try self.adapter.recordScene(&self.surface, &self.recording, &output, &painted);
        // `present` closes the recording itself, so a present that fails
        // must propagate its own error rather than reach a cancellation of a
        // recording that is gone.
        try self.adapter.present(&self.surface, &self.recording);
        managed.markPresented();
        self.pixels = try self.adapter.readTarget();
        self.extent = self.recording.image;
        self.logical = logical;
        self.frames += 1;
        return true;
    }

    /// Acquire the next image, retarget the Oklab pass to it and open the
    /// recording. A swapchain that is out of date is not a failure: the
    /// acquire is retried inside this bound, so a driver that never settles
    /// fails the run instead of spinning.
    fn beginFrame(self: *Self, viewport: NativeFrame.Viewport) !bool {
        var attempts: u32 = 0;
        while (attempts < acquire_polls) : (attempts += 1) {
            if (try self.adapter.beginFrame(&self.surface, viewport, &self.recording)) return true;
            self.retries += 1;
        }
        return error.SwapchainNeverSettled;
    }

    fn cancelRecording(self: *Self) void {
        self.adapter.cancelFrame(&self.recording) catch |err| switch (err) {
            error.FrameNotRecording => {},
            else => @panic("menu-overlay native recording cancellation failed"),
        };
    }

    /// Ask the host for one more frame and run it. The W05 task service is
    /// drained by the host's own `step`, so a deadline this run moved the
    /// injected clock to is delivered through the production path and never
    /// by a private scheduler.
    fn pump(self: *Self) !void {
        const before = self.frames;
        try self.scenario.session.requestRedraw(self.scenario.app.window);
        var polls: u32 = 0;
        while (polls < frame_polls and self.frames == before) : (polls += 1) {
            if (!try self.application.step()) return error.HostStoppedEarly;
        }
        if (self.frames == before) return error.NoFrameForStep;
    }

    // ── external input: requests out, real events in ──────────────────
    //
    // Nothing in this arm fabricates an event. Every pointer, key and focus
    // change it needs is published as an exact command for an external
    // controller to run against THIS window, and then waited for on the
    // host's own delivery: the request is what a person has to do, the model
    // change is the proof, and the wait is bounded, so an unanswered request
    // fails the run by name instead of hanging.

    /// How long one request may wait for the event it asks for.
    const controller_budget_ms: u64 = 5_000;

    /// The identifier every REQUEST names: the X11 window, never the SDL
    /// window id. `run` refuses the arm before the first step when the
    /// platform published no X11 identifier, so this unwrap is the one case
    /// the run has already excluded.
    fn window(self: *const Self) u32 {
        return @intCast(self.x11_window.?);
    }

    fn request(self: *Self, comptime format: []const u8, args: anytype) !void {
        try self.emit("REQUEST " ++ format ++ "\n", args);
    }

    /// Pump the host until the wait is satisfied or the budget expires. Each
    /// pass is the production one: SDL's own queue, this host's dispatch, the
    /// Session's W05 task service, and the window's frame callback.
    fn waitUntil(self: *Self, context: anytype) !void {
        var waited: u64 = 0;
        while (!context.done()) {
            if (!try self.application.step()) return error.HostStoppedEarly;
            if (context.done()) break;
            if (waited >= controller_budget_ms) return error.ControllerDidNotDeliver;
            const asked = (try self.application.nextWaitMilliseconds()) orelse 1;
            const slice = @min(@as(u64, asked), controller_budget_ms - waited);
            try std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(@intCast(slice)), .real);
            waited += slice;
        }
    }

    /// What a bounded wait is waiting for. Each names one real effect, so a
    /// timeout can say which request went unanswered.
    const CounterWait = struct {
        counter: *const u32,
        from: u32,
        by: u32 = 1,

        fn done(self: CounterWait) bool {
            return self.counter.* >= self.from +| self.by;
        }
    };

    const MovedWait = struct {
        offset: *const f32,
        from: f32,

        fn done(self: MovedWait) bool {
            return self.offset.* != self.from;
        }
    };

    const PredicateWait = struct {
        view: *MenuView,
        getter: *const fn (*MenuView) bool,

        fn done(self: PredicateWait) bool {
            return self.getter(self.view);
        }
    };

    fn tooltipArmed(view: *MenuView) bool {
        return view.tip.deadline() != null;
    }

    fn tooltipIdle(view: *MenuView) bool {
        return view.tip.deadline() == null;
    }

    fn tipShown(view: *MenuView) bool {
        return view.tip.visible();
    }

    /// Wait for a routed counter to advance by at least `by`: the proof that
    /// real events reached this view.
    fn awaitCounter(self: *Self, counter: *const u32, from: u32, by: u32) !void {
        try self.waitUntil(CounterWait{ .counter = counter, .from = from, .by = by });
    }

    /// Wait for a value the consumer's own model owns to move — the scroll
    /// offset a real wheel event writes.
    fn awaitMoved(self: *Self, offset: *const f32, from: f32) !void {
        try self.waitUntil(MovedWait{ .offset = offset, .from = from });
    }

    /// Wait for a predicate over the view, which is where a real event's
    /// effect lands.
    fn awaitTrue(self: *Self, getter: *const fn (*MenuView) bool) !void {
        try self.waitUntil(PredicateWait{ .view = self.scenario.view, .getter = getter });
    }

    // ── reading the presented frame back ───────────────────────────────

    /// The Oklab the menu's authored sRGB lands in, through the frame
    /// module's own public conversion — the same one the paint pipeline
    /// applied to the authored colour.
    fn labMenu() [4]f32 {
        return frame_mod.srgbToOklab(menu_fill);
    }

    fn labTip() [4]f32 {
        return frame_mod.srgbToOklab(tip_fill);
    }

    /// Distance in Oklab, over L, a and b. Alpha is not compared: a fill is
    /// opaque and the pass underneath it is opaque too.
    fn labDistance(a: [4]f32, b: [4]f32) f32 {
        const dl = a[0] - b[0];
        const da = a[1] - b[1];
        const db = a[2] - b[2];
        return @sqrt(dl * dl + da * da + db * db);
    }

    /// Device pixels per logical unit, taken from the presented image itself
    /// rather than from the display scale, so a probe and the buffer it reads
    /// can never disagree about where a logical rect landed.
    fn probeScale(self: *const Self) f32 {
        return @as(f32, @floatFromInt(self.extent.width)) / self.logical.width;
    }

    fn readPixel(self: *const Self, x: u32, y: u32) [4]f32 {
        const row = @as(usize, y) * @as(usize, self.extent.width);
        const base = (row + @as(usize, x)) * 4;
        return .{
            self.pixels[base],
            self.pixels[base + 1],
            self.pixels[base + 2],
            self.pixels[base + 3],
        };
    }

    /// The device-pixel window one logical rect probes, inset by
    /// `probe_inset` so no border, rounded corner or antialiased edge is ever
    /// read as a fill. It is the SAME window for every colour a census counts,
    /// so the counts are comparable.
    const Bounds = struct { x0: u32, y0: u32, x1: u32, y1: u32 };

    fn probeBounds(self: *const Self, rect: widget.Rect) Bounds {
        const empty: Bounds = .{ .x0 = 0, .y0 = 0, .x1 = 0, .y1 = 0 };
        if (rect.w <= 0 or rect.h <= 0) return empty;
        const scale = self.probeScale();
        const left = @max(0, (rect.x + probe_inset) * scale);
        const top = @max(0, (rect.y + probe_inset) * scale);
        const right = @min(
            @as(f32, @floatFromInt(self.extent.width)),
            (rect.x + rect.w - probe_inset) * scale,
        );
        const bottom = @min(
            @as(f32, @floatFromInt(self.extent.height)),
            (rect.y + rect.h - probe_inset) * scale,
        );
        if (right <= left or bottom <= top) return empty;
        return .{
            .x0 = @intFromFloat(@floor(left)),
            .y0 = @intFromFloat(@floor(top)),
            .x1 = @min(self.extent.width, @as(u32, @intFromFloat(@ceil(right)))),
            .y1 = @min(self.extent.height, @as(u32, @intFromFloat(@ceil(bottom)))),
        };
    }

    /// How many of a rect's probed device pixels carry `color`.
    fn countColor(self: *const Self, rect: widget.Rect, color: [4]f32) usize {
        const bounds = self.probeBounds(rect);
        var total: usize = 0;
        var y = bounds.y0;
        while (y < bounds.y1) : (y += 1) {
            var x = bounds.x0;
            while (x < bounds.x1) : (x += 1) {
                if (labDistance(self.readPixel(x, y), color) <= lab_match_tolerance) total += 1;
            }
        }
        return total;
    }

    /// How many device pixels a rect probes at all. "Every pixel here is the
    /// clear" is `clear == total`, at whatever scale the window presented.
    fn countPixels(self: *const Self, rect: widget.Rect) usize {
        const bounds = self.probeBounds(rect);
        return @as(usize, bounds.x1 - bounds.x0) * @as(usize, bounds.y1 - bounds.y0);
    }

    /// What the presented frame carries inside one rect: how many of its
    /// probed pixels are each overlay's own fill, how many are the colour the
    /// Oklab pass cleared its target to, and how many there were. Every pixel
    /// claim in this file is made against this census.
    const Census = struct {
        menu: usize,
        tip: usize,
        clear: usize,
        total: usize,
    };

    fn census(self: *const Self, rect: widget.Rect) Census {
        return .{
            .menu = self.countColor(rect, labMenu()),
            .tip = self.countColor(rect, labTip()),
            .clear = self.countColor(rect, frame_mod.scene.oklab_clear),
            .total = self.countPixels(rect),
        };
    }

    // ── committed-tree readers ────────────────────────────────────────

    /// The App's current committed tree, MUTABLE: `overlay.Frame.stage`
    /// registers the clip rects it computes on the tree it is handed.
    fn liveTree(self: *Self) !*widget.WidgetTree {
        return self.scenario.app.tree_ptr orelse error.RootNotMounted;
    }

    fn menuRect(self: *Self) !widget.Rect {
        const view = self.scenario.view;
        const tree = try self.liveTree();
        const placement = view.frame.placement(tree, view.widget(key_menu) orelse
            return error.MissingMenu) orelse return error.UnplacedMenu;
        return placement.rect;
    }

    fn tipRect(self: *Self) !widget.Rect {
        const view = self.scenario.view;
        const tree = try self.liveTree();
        const placement = view.frame.placement(tree, view.widget(key_tip) orelse
            return error.MissingTip) orelse return error.UnplacedTip;
        return placement.rect;
    }

    /// The part of the menu that the tooltip does not cover: where the
    /// menu's own fill is the only fill that can be on screen.
    fn menuOnlyBand(menu: widget.Rect, tip: widget.Rect) widget.Rect {
        const top = @max(menu.y, tip.y + tip.h);
        return .{
            .x = menu.x,
            .y = top,
            .w = menu.w,
            .h = @max(0, menu.y + menu.h - top),
        };
    }

    /// Canvas the scene never draws into: below the scroller, right of the
    /// menu bar. Whatever the frame shows there is what the Oklab pass
    /// cleared to, and nothing else.
    fn backgroundRect() widget.Rect {
        return .{ .x = surface.width - 24, .y = surface.height - 24, .w = 16, .h = 16 };
    }

    // ── the report ────────────────────────────────────────────────────

    fn emit(self: *Self, comptime format: []const u8, args: anytype) !void {
        const text = std.fmt.bufPrint(&self.report, format, args) catch
            return error.ReportTooLong;
        try std.Io.File.stdout().writeStreamingAll(self.io, text);
    }

    // ── the run ───────────────────────────────────────────────────────

    pub fn run(self: *Self) !void {
        const observed = self.managed.observed;
        if (!observed.visible) return error.NativeWindowIsNotVisible;
        // An X client aims at the X11 identifier, which the platform publishes
        // in SDL's own property store. A backend that publishes none leaves
        // every request unanswerable, so the arm says so here instead of
        // printing commands against a number that means nothing outside this
        // process.
        if (self.x11_window == null) return error.NoX11WindowIdentifier;
        // The window answered a size this scene's geometry assumes. A
        // platform that gave something else is reported, never absorbed.
        if (observed.size.width != native_width or observed.size.height != native_height) {
            return error.NativeWindowRefusedGeometry;
        }
        // The oracle's own margin, checked before it is used to judge
        // anything: a pixel within `lab_match_tolerance` of one fill must be
        // impossible to mistake for the other, and neither fill may be the
        // colour the Oklab pass cleared to.
        const separation = labDistance(labMenu(), labTip());
        if (separation <= lab_match_tolerance * 2) return error.FillsAreNotDistinguishable;
        if (labDistance(labMenu(), frame_mod.scene.oklab_clear) <= lab_distinct_tolerance) {
            return error.MenuFillMatchesTheCanvasClear;
        }
        if (labDistance(labTip(), frame_mod.scene.oklab_clear) <= lab_distinct_tolerance) {
            return error.TooltipFillMatchesTheCanvasClear;
        }
        // The two identifiers this window has, kept apart on purpose: the SDL
        // window id is a handle into THIS process, and the X11 window is the
        // one an outside controller may aim at. Nothing this arm does ever
        // touches another window.
        try self.emit(
            "WINDOW title={s} sdl_window_id={d} x11_window={any} driver={s} logical={d}x{d} device={d}x{d} visible={} fill_separation={d:.3} match_tolerance={d:.3} budget_ms={d}\n",
            .{
                self.options.title,
                self.native_id,
                self.x11_window,
                self.driver,
                observed.size.width,
                observed.size.height,
                observed.pixels.width,
                observed.pixels.height,
                observed.visible,
                separation,
                lab_match_tolerance,
                controller_budget_ms,
            },
        );
        try self.emit(
            "CONTROLLER target=x11_window:{any} aux_title={s} tool=xdotool input=platform-delivered-events focus_transfer=aux-window\n",
            .{ self.x11_window, native_aux_title },
        );

        // The first frame, so the committed tree every step reads exists
        // before step one and the run is never half a scene.
        try self.pump();
        if (self.options.controller) return self.runController();
        if (self.options.only) |name| {
            try self.runStep(Step.parse(name).?);
        } else {
            for (Step.names, 0..) |_, index| {
                try self.runStep(@fromBackingInt(@intCast(index)));
            }
        }
        try self.reportDone();
    }

    /// One step, one line. A step that fails says so on the report stream and
    /// then returns its error, so the process exits nonzero and the line is
    /// the last thing the controller reads.
    fn runStep(self: *Self, step: Step) !void {
        const name = Step.names[@backingInt(step)];
        try self.emit("STEP {s} begin\n", .{name});
        self.execute(step) catch |err| {
            try self.emit("STEP {s} FAIL {s} claims={d}\n", .{
                name,
                @errorName(err),
                self.claims,
            });
            return err;
        };
        // The capture is the frame this step left on the window, read back out
        // of the Oklab target the presented passes wrote and written as sRGB
        // bytes. Any step can be the captured one; `--capture-step` names it.
        if (self.options.capture) |path| {
            if (Step.parse(self.options.capture_step).? == step) {
                try frame_mod.writePpm(self.gpa, self.io, path, self.pixels, self.extent);
                try self.emit("CAPTURE step={s} path={s} {d}x{d}\n", .{
                    name,
                    path,
                    self.extent.width,
                    self.extent.height,
                });
            }
        }
    }

    fn reportDone(self: *Self) !void {
        const stats = self.adapter.stats;
        try self.emit(
            "DONE steps={d} claims={d} frames={d} presented={d} acquire_retries={d} readback={d}x{d} presented_ok={} window_alive={}\n",
            .{
                Step.names.len,
                self.claims,
                self.frames,
                stats.frames_presented,
                self.retries,
                self.extent.width,
                self.extent.height,
                stats.frames_presented == self.frames,
                !self.window_dead,
            },
        );
        // Every frame this arm built reached the swapchain image, and the
        // pixels every probe read are out of that frame's own Oklab target.
        if (self.adapter_live and stats.frames_presented != self.frames) {
            return error.PresentDidNotFollowEveryFrame;
        }
    }

    /// Take the step list from stdin, one name per line. `quit` stops. The
    /// script is bounded twice — bytes and steps — because it is another
    /// process's data.
    fn runController(self: *Self) !void {
        var buffer: [1024]u8 = undefined;
        var reader = std.Io.File.stdin().reader(self.io, &buffer);
        const script = try reader.interface.allocRemaining(
            self.gpa,
            std.Io.Limit.limited(controller_script_limit),
        );
        defer self.gpa.free(script);
        try self.emit("CONTROLLER ready steps={d}\n", .{Step.names.len});
        var ran: usize = 0;
        var lines = std.mem.splitScalar(u8, script, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0) continue;
            if (std.mem.eql(u8, line, "quit")) break;
            ran += 1;
            if (ran > controller_step_limit) return error.ControllerScriptUnbounded;
            const step = Step.parse(line) orelse return error.UnknownStep;
            try self.runStep(step);
        }
        try self.reportDone();
    }

    fn execute(self: *Self, step: Step) !void {
        switch (step) {
            .frame => try self.stepFrame(),
            .open => try self.stepOpen(),
            .scroll => try self.stepScroll(),
            .hover => try self.stepHover(),
            .tip_due => try self.stepTipDue(),
            .order => try self.stepOrder(),
            .escape => try self.stepEscape(),
            .threshold => try self.stepThreshold(),
            .capture_lost => try self.stepCaptureLost(),
            .refuse => try self.stepRefuse(),
            .accept => try self.stepAccept(),
            .tip_leave => try self.stepTipLeave(),
            .tip_remove => try self.stepTipRemove(),
            .reopen => try self.stepReopen(),
            .closing => try self.stepClosing(),
        }
    }

    /// One oracle. A claim that holds is counted; a claim that does not is
    /// named by its own error value, which is what reaches the report line and
    /// what makes the process exit nonzero.
    fn expect(self: *Self, ok: bool, comptime err: anyerror) !void {
        if (!ok) {
            self.failed = err;
            return err;
        }
        self.claims += 1;
    }

    // ── step 1: the first committed, presented frame ──────────────────

    fn stepFrame(self: *Self) !void {
        const view = self.scenario.view;
        const tree = try self.liveTree();
        try self.expect(self.frames > 0, error.NoPresentedFrame);
        try self.expect(view.widget(key_file) != null, error.MissingCommittedWidget);
        try self.expect(view.routed == 0, error.RoutedBeforeAnyInput);
        // The Oklab pass clears its own target, and this scene paints nothing
        // in this corner, so the readback is the clear colour there. It is
        // the control that every later pixel claim is measured against.
        const empty = self.census(backgroundRect());
        try self.expect(empty.total > 0, error.CannotProbeTheCanvas);
        try self.expect(empty.clear == empty.total, error.CanvasIsNotTheOklabClear);
        try self.expect(
            empty.menu == 0 and empty.tip == 0,
            error.OverlayPaintedBeforeItWasPlaced,
        );
        try self.emit(
            "STEP frame OK frames={d} tick={d} nodes={d} canvas_clear={d} menu_px={d} tip_px={d}\n",
            .{ self.frames, self.tick, tree.nodes.items.len, empty.clear, empty.menu, empty.tip },
        );
    }

    // ── step 2: a real click opens the menu, and it is placed ─────────

    fn stepOpen(self: *Self) !void {
        const view = self.scenario.view;
        const point = try self.scenario.centreOf(key_file);
        // Every counter this step judges is read HERE, before the request, so
        // the claims below are deltas on THIS step's own click and not totals
        // for the whole run. One request is one click, and one click is one
        // activation: the wait only bounds the arrival, the claims are what
        // say the click arrived once.
        const clicks = view.file_clicks;
        const opens = view.menu_opens;
        // The releases and activations this step's own click produced, read
        // HERE beside the two model counters. One request is one press/release
        // pair and one activation, and these are the claims that say the PAIR
        // arrived once. The model counters alone cannot: a second pair the
        // open menu swallowed would move neither of them, and would pass.
        const releases = view.mouse_ups;
        const activations = view.activations;
        try self.request(
            "xdotool mousemove --sync --window {d} {d:.0} {d:.0} click 1  # committed centre of menu-file",
            .{ self.window(), point[0], point[1] },
        );
        try self.awaitCounter(&view.file_clicks, clicks, 1);
        try self.pump();

        // What this step's own click actually produced, published before any
        // claim below can fail. A refusal that names only an error leaves the
        // reader guessing which counter was wrong; these numbers are the ones
        // the claims judge, so one run says what it observed — including the
        // releases and activations the platform actually delivered, which is
        // what tells a duplicated click pair apart from a duplicated callback.
        try self.emit(
            "COUNTS step=open clicks={d} opens={d} routed={d} releases={d} activations={d}\n",
            .{
                view.file_clicks - clicks,
                view.menu_opens - opens,
                view.routed,
                view.mouse_ups - releases,
                view.activations - activations,
            },
        );
        try self.expect(view.open_menu, error.MenuDidNotOpen);
        try self.expect(view.file_clicks == clicks + 1, error.FileClickCount);
        try self.expect(view.menu_opens == opens + 1, error.MenuOpenNotCounted);
        // The pair itself, told apart. More releases than the one request asked
        // for is the platform delivering one click twice; more activations than
        // releases is one release firing twice. Both are this step's own
        // counts, not totals for the run, and both name themselves instead of
        // surfacing as whichever model counter they happen to move.
        try self.expect(view.mouse_ups - releases == 1, error.ClickDeliveredMoreThanOneRelease);
        try self.expect(view.activations - activations == 1, error.ClickActivatedMoreThanOnce);
        const tree = try self.liveTree();
        const menu_id = view.widget(key_menu) orelse return error.MissingMenu;
        const placement = view.frame.placement(tree, menu_id) orelse return error.UnplacedMenu;
        const rect = placement.rect;
        try self.expect(rect.w > 0 and rect.h > 0, error.DegenerateMenuPlacement);
        try self.expect(rect.x >= 0 and rect.y >= 0, error.MenuOutsideTheViewportOrigin);
        try self.expect(
            rect.x + rect.w <= surface.width and rect.y + rect.h <= surface.height,
            error.MenuOutsideTheViewport,
        );
        // Window escape imposes no clip of its own: the menu's own ancestry
        // still applies, and the placement wrote no clip onto its root.
        const menu_node = tree.frameNode(menu_id) orelse return error.MissingMenu;
        try self.expect(tree.node(menu_node).?.placement_clip == null, error.MenuInheritedAClip);
        // The menu took the keyboard: focus moved into it, through the App's
        // own focus observer.
        try self.expect(
            view.focus_after_open != null and view.focus_after_open.?.eql(
                view.widget(key_item).?,
            ),
            error.MenuDidNotTakeFocus,
        );
        try self.emit(
            "STEP open OK rect={d:.0},{d:.0} {d:.0}x{d:.0} order={d} focus_in_menu=true\n",
            .{ rect.x, rect.y, rect.w, rect.h, placement.order },
        );
    }

    // ── step 3: a real wheel scrolls the anchor and the popup follows ─

    fn stepScroll(self: *Self) !void {
        const view = self.scenario.view;
        const before = try self.menuRect();
        self.menu_before_scroll = before;
        const point = try self.scenario.centreOf(key_anchor);
        const offset = view.scroll.offset[1];
        try self.request(
            "xdotool mousemove --sync --window {d} {d:.0} {d:.0} click --repeat 1 5  # WHEEL DOWN over menu-anchor: X11 button 5 is a positive scroll_y",
            .{ self.window(), point[0], point[1] },
        );
        try self.awaitMoved(&view.scroll.offset[1], offset);
        try self.pump();

        const after = try self.menuRect();
        self.menu_after_scroll = after;
        const delta = view.scroll.offset[1] - offset;
        try self.expect(delta > 0, error.WheelDidNotScroll);
        // How far the popup actually travelled, measured rather than assumed:
        // one notch is 20 units headless and whatever the native scrollbar
        // step is, so this reads the delta instead of hard-coding it.
        const moved = before.y - after.y;
        try self.expect(moved > 0, error.PopupDidNotFollowItsAnchor);
        // It follows the anchor UP by its anchor's scroll and no further, and
        // `overlay.Frame.fit` may hold it off the viewport edge — which shows
        // up here as a distance SMALLER than the scroll, never a larger one.
        try self.expect(
            moved <= delta + 0.01,
            error.PopupMovedFurtherThanItsAnchor,
        );
        try self.emit(
            "STEP scroll OK offset={d:.0} menu_y {d:.0} -> {d:.0} moved={d:.0} followed={}\n",
            .{ delta, before.y, after.y, moved, std.math.approxEqAbs(f32, moved, delta, 0.01) },
        );
    }

    // ── step 4: a real hover arms the W05 timer and nothing more ──────

    fn stepHover(self: *Self) !void {
        const view = self.scenario.view;
        const point = try self.scenario.centreOf(key_hint);
        const moves = view.pointer_moves;
        try self.request(
            "xdotool mousemove --sync --window {d} {d:.0} {d:.0}  # committed centre of menu-hint",
            .{ self.window(), point[0], point[1] },
        );
        try self.awaitCounter(&view.pointer_moves, moves, 1);
        try self.awaitTrue(&tooltipArmed);
        try self.pump();

        const deadline = view.tip.deadline().?;
        self.first_deadline_ns = deadline.at_ns;
        // The deadline the tooltip computed IS the deadline the Session's W05
        // service is waiting for, and it is in the FUTURE because the clock
        // under both of them is the production monotonic one.
        const service = (try self.scenario.session.nextTaskDeadline()) orelse
            return error.MissingServiceDeadline;
        try self.expect(service == deadline.at_ns, error.ServiceDeadlineIsNotTheTooltipDeadline);
        try self.expect(
            deadline.at_ns > self.scenario.clock.now(),
            error.TooltipDeadlineIsNotInTheFuture,
        );
        try self.expect(view.tip_arms == 1, error.TimerArmedMoreThanOnce);
        try self.expect(!view.tip.visible(), error.TooltipVisibleBeforeItsDeadline);
        const stats = try self.scenario.tipStats();
        try self.expect(stats.delivered == 0, error.TooltipDeliveredEarly);
        // Nothing is placed yet, so the frame still shows only the canvas.
        const empty = self.census(backgroundRect());
        try self.expect(empty.clear == empty.total, error.CanvasIsNotTheOklabClear);
        try self.emit(
            "STEP hover OK deadline_in={d}ms service_in={d}ms arms={d} visible=false\n",
            .{
                @divTrunc(deadline.at_ns - self.scenario.clock.now(), std.time.ns_per_ms),
                @divTrunc(service - self.scenario.clock.now(), std.time.ns_per_ms),
                view.tip_arms,
            },
        );
    }

    // ── step 5: the real deadline is what shows it, through W05 ───────

    fn stepTipDue(self: *Self) !void {
        const view = self.scenario.view;
        // No clock is moved here and none is needed: the deadline is the
        // production one, and the wait is the Session's own W05 service
        // deciding that it has arrived.
        try self.awaitTrue(&tipShown);
        try self.pump();

        const stats = try self.scenario.tipStats();
        try self.expect(stats.delivered == 1, error.TooltipDeliveryCount);
        try self.expect(stats.fired == 1, error.TooltipDeliveryDidNotFire);
        try self.expect(stats.visible, error.TooltipNotVisibleAfterItsDeadline);
        try self.expect(view.tip_shows == 1, error.TooltipShowCount);
        // Hoverable bounds: the placed rect is published, so the pointer can
        // move ONTO the content without dismissing it.
        try self.expect(view.tip_bounds_set, error.TooltipBoundsNotPublished);
        const rect = try self.tipRect();
        const painted = self.census(rect);
        try self.expect(painted.tip > 0, error.TooltipDidNotPaintItsOwnFill);
        try self.emit(
            "STEP tip-due OK delivered={d} fired={d} visible=true rect={d:.0},{d:.0} {d:.0}x{d:.0} tip_px={d}\n",
            .{ stats.delivered, stats.fired, rect.x, rect.y, rect.w, rect.h, painted.tip },
        );
    }

    // ── step 6: one key decides both the paint order and the hit order ─

    fn stepOrder(self: *Self) !void {
        const view = self.scenario.view;
        const tree = try self.liveTree();
        const menu = try self.menuRect();
        const tip = try self.tipRect();
        const shared = overlapRect(menu, tip) orelse return error.OverlaysDoNotOverlap;

        const menu_node = tree.frameNode(view.widget(key_menu).?) orelse return error.MissingMenu;
        const tip_node = tree.frameNode(view.widget(key_tip).?) orelse return error.MissingTip;
        // The layers the painter EMITS for those two roots, read through the
        // same function the scene sorts by, beside the highest layer the
        // application itself authors. A band starts above that maximum, so
        // these three numbers decide both claims on their own: the popup is
        // above the application, and the higher-priority popup is above the
        // other one, because one (priority, registration) key chose both.
        const menu_layer = try widget.effectiveLayer(
            tree.nodeConst(menu_node) orelse return error.MissingMenuPaint,
            0,
        );
        const tip_layer = try widget.effectiveLayer(
            tree.nodeConst(tip_node) orelse return error.MissingTipPaint,
            0,
        );
        const app_max = try widget.maximumPaintLayer(tree);
        const menu_key = (view.frame.placement(tree, view.widget(key_menu).?) orelse
            return error.UnplacedMenu).order;
        const tip_key = (view.frame.placement(tree, view.widget(key_tip).?) orelse
            return error.UnplacedTip).order;
        try self.expect(tip_key > menu_key, error.PaintOrderDoesNotFollowPriority);
        try self.expect(tip_layer > menu_layer, error.PaintLayerDoesNotFollowPriority);
        try self.expect(menu_layer > app_max, error.PopupDidNotClearTheApplicationLayers);

        // HIT ORDER, from the engine's own resolution: the overlapping point
        // belongs to the higher-priority overlay's subtree, and to nothing in
        // the menu's.
        const point: [2]f32 = .{ shared.x + shared.w / 2, shared.y + shared.h / 2 };
        const pick = view.frame.hitTest(tree, point) orelse return error.MissedOverlay;
        try self.expect(withinSubtree(tree, pick, tip_node), error.OverlayPickIsNotTheTooltip);
        try self.expect(!withinSubtree(tree, pick, menu_node), error.OverlayPickIsAlsoTheMenu);
        const routed = view.frame.hitTestTotal(tree, point) orelse return error.MissedRouting;
        try self.expect(withinSubtree(tree, routed, tip_node), error.RoutingIsNotTheTopmostOverlay);

        // ROUTING, through the window: a real click on that point reaches the
        // tooltip and activates nothing underneath it.
        const items = view.item_clicks;
        const cards = view.card_clicks;
        const ups = view.mouse_ups;
        const acts = view.activations;
        try self.request(
            "xdotool mousemove --sync --window {d} {d:.0} {d:.0} click 1  # centre of the OVERLAP, both popups",
            .{ self.window(), point[0], point[1] },
        );
        // The click is waited for by the release that carries it and the
        // activation that ends it — both real, both this request's own. A
        // routed count would be satisfied by the pair's intermediate dispatches
        // and could return while the release was still in the queue.
        try self.awaitCounter(&view.mouse_ups, ups, 1);
        try self.awaitCounter(&view.activations, acts, 1);
        try self.pump();
        try self.expect(view.item_clicks == items, error.CoveredItemWasActivated);
        try self.expect(view.card_clicks == cards, error.CoveredCardWasActivated);

        // PAINT ORDER, in the pixels of the frame the window was showing:
        // where the two overlays overlap only the tooltip's fill survives,
        // and where only the menu reaches, only the menu's fill does.
        const shared_px = self.census(shared);
        try self.expect(shared_px.tip > 0, error.OverlapIsNotPaintedByTheTopmost);
        try self.expect(shared_px.menu == 0, error.OverlapStillShowsTheMenuUnderneath);
        const band = menuOnlyBand(menu, tip);
        const band_px = self.census(band);
        try self.expect(band_px.menu > 0, error.MenuDidNotPaintItsOwnFill);
        try self.expect(band_px.tip == 0, error.TooltipPaintedOutsideItsBox);
        try self.emit(
            "STEP order OK point={d:.0},{d:.0} winner=tooltip menu_key={d} tip_key={d} menu_layer={d} tip_layer={d} app_max={d} overlap_tip_px={d} overlap_menu_px={d} band_menu_px={d}\n",
            .{ point[0], point[1], menu_key, tip_key, menu_layer, tip_layer, app_max, shared_px.tip, shared_px.menu, band_px.menu },
        );
    }

    // ── step 7: the keyboard returns focus to the surviving prior target ─

    fn stepEscape(self: *Self) !void {
        const view = self.scenario.view;
        const closes = view.menu_closes;
        try self.request(
            "xdotool key --window {d} Escape  # the menu owns the keyboard while it is open",
            .{self.window()},
        );
        try self.awaitCounter(&view.menu_closes, closes, 1);
        try self.pump();
        // The focus this step left behind, read out of the App's own manager
        // here for the same reason `specimen` reads it there: that read is the
        // only writer of this field outside `afterFrame`, so in this arm it
        // stayed null for the whole run and the claims below could only ever
        // be empty. `afterFrame` records `focus_after_open` the same way, so
        // both arms name each move with one field read from one place.
        view.focus_after_escape = self.scenario.app.focus_manager.current;

        try self.expect(!view.open_menu, error.EscapeDidNotCloseTheMenu);
        // The scope restored a LIVE target instead of blurring.
        try self.expect(view.focus_restores == 1, error.FocusWasBlurredNotRestored);
        const file = view.widget(key_file) orelse return error.MissingFile;
        try self.expect(view.focus_after_escape != null, error.FocusIsEmptyAfterEscape);
        try self.expect(view.focus_after_escape.?.eql(file), error.FocusDidNotReturnToThePriorTarget);
        // The menu left the tree, and the frame says so in pixels too.
        try self.expect(view.widget(key_menu) == null, error.MenuSurvivedInTheCommittedTree);
        const gone = self.census(self.menu_before_scroll);
        try self.expect(gone.menu == 0, error.MenuFillStillOnScreenAfterClosing);
        try self.emit(
            "STEP escape OK closes={d} focus_restores={d} focus=file menu_px={d}\n",
            .{ view.menu_closes, view.focus_restores, gone.menu },
        );
    }

    // ── step 8: a move under the threshold is not a drag ──────────────

    fn stepThreshold(self: *Self) !void {
        const view = self.scenario.view;
        const card = try self.scenario.centreOf(key_card);
        self.drag_base = view.dragSnapshot();
        // Each request is waited for by what IT does: the press by the capture
        // the card takes, the one-pixel move by the move itself. `view.routed`
        // is not a pointer counter, so a wait on it is satisfied by dispatches
        // that are not the event being waited for.
        try self.request(
            "xdotool mousemove --sync --window {d} {d:.0} {d:.0} mousedown 1  # committed centre of menu-card",
            .{ self.window(), card[0], card[1] },
        );
        try self.awaitTrue(&dragCaptured);
        const moves = view.pointer_moves;
        try self.request(
            "xdotool mousemove --sync --window {d} {d:.0} {d:.0}  # ONE pixel: under the drag threshold",
            .{ self.window(), card[0] + 1, card[1] },
        );
        try self.awaitCounter(&view.pointer_moves, moves, 1);
        try self.pump();

        const snapshot = try self.emitDrag("threshold", self.drag_base);
        try self.expect(snapshot.enters == 0, error.DragBeganUnderTheThreshold);
        try self.expect(snapshot.cancels == 0, error.DragCancelledUnderTheThreshold);
        // The field the headless arm writes, so one refused move is one move in
        // both arms rather than two counters only one arm ever touched.
        view.under_threshold_moves += 1;
        // The press is real and captured by the card; only the drag is not
        // there yet.
        try self.expect(dragCaptured(view), error.PressDidNotCaptureTheCard);
        try self.emit(
            "STEP threshold OK under_threshold_moves={d} enters={d} captured=true\n",
            .{ view.under_threshold_moves, snapshot.enters },
        );
    }

    // ── step 9: the window losing focus cancels exactly once ──────────

    fn stepCaptureLost(self: *Self) !void {
        const view = self.scenario.view;
        const drop = try self.scenario.centreOf(key_drop);
        const moves = view.pointer_moves;
        try self.request(
            "xdotool mousemove --sync --window {d} {d:.0} {d:.0}  # cross the threshold onto menu-drop",
            .{ self.window(), drop[0], drop[1] },
        );
        try self.awaitCounter(&view.pointer_moves, moves, 1);
        const cancels = view.outside_cancels;
        // The WINDOW loses focus to a private auxiliary window the controller
        // owns. That is a real platform event: the platform delivers it, the
        // engine's own reset revokes the capture, and the drag is cancelled —
        // never committed. This arm never manufactures the loss, and it names
        // only the controller's OWN window.
        try self.request(
            "xdotool search --sync --name {s} windowfocus --sync  # controller-owned private window takes the focus; the platform delivers the loss",
            .{native_aux_title},
        );
        try self.awaitCounter(&view.outside_cancels, cancels, 1);
        try self.pump();

        const snapshot = try self.emitDrag("capture-lost", self.drag_base);
        try self.expect(snapshot.enters == 1, error.DragDidNotReachTheTarget);
        try self.expect(snapshot.leaves == 1, error.DragTargetDidNotLeave);
        try self.expect(snapshot.cancels == 1, error.CaptureLossDidNotCancelExactlyOnce);
        try self.expect(snapshot.checks == 0, error.CancelledDragAskedToCommit);
        try self.expect(snapshot.drops == 0, error.CancelledDragDropped);
        try self.expect(snapshot.frees == 1, error.CancelledDragDidNotFreeOnce);
        try self.expect(
            self.scenario.app.focus_manager.current == null,
            error.FocusSurvivedTheWindowLosingIt,
        );
        try self.emit(
            "STEP capture-lost OK enters={d} leaves={d} cancels={d} checks={d} drops={d} frees={d} outside_cancels={d}\n",
            .{
                snapshot.enters,      snapshot.leaves, snapshot.cancels,
                snapshot.checks,      snapshot.drops,  snapshot.frees,
                view.outside_cancels,
            },
        );
    }

    /// One real drag, card to drop target, as the exact command a controller
    /// runs. The four routed events the caller waits for are the move, the
    /// press, the threshold crossing and the release.
    fn requestDrag(self: *Self) !void {
        const from = try self.scenario.centreOf(key_card);
        const to = try self.scenario.centreOf(key_drop);
        try self.request(
            "xdotool mousemove --sync --window {d} {d:.0} {d:.0} mousedown 1 mousemove --sync --window {d} {d:.0} {d:.0} mouseup 1  # committed centres of menu-card and menu-drop",
            .{ self.window(), from[0], from[1], self.window(), to[0], to[1] },
        );
    }

    /// The per-drag counters, published BEFORE the claims below judge them. A
    /// refusal that names only its error leaves the reader guessing which of
    /// the nine counters disagreed; this line says what the drag produced, so
    /// one run names it. Every field is a delta on this drag alone, against
    /// the base its caller snapshotted before this step's first request.
    fn emitDrag(self: *Self, step: []const u8, base: DragSnapshot) !DragSnapshot {
        const now = self.scenario.view.dragSnapshot();
        const snapshot = now.since(base);
        try self.emit(
            "COUNTS step={s} enters={d} moves={d} leaves={d} checks={d} cancels={d} drops={d} frees={d} payload_frees={d} card_clicks={d} foreign_reads={d}\n",
            .{
                step,                 snapshot.enters,        snapshot.moves,
                snapshot.leaves,      snapshot.checks,        snapshot.cancels,
                snapshot.drops,       snapshot.frees,         now.frees,
                snapshot.card_clicks, snapshot.foreign_reads,
            },
        );
        return snapshot;
    }

    // ── step 10: a target that refuses runs the cancel path ───────────

    fn stepRefuse(self: *Self) !void {
        const view = self.scenario.view;
        view.accept_drops = false;
        self.drag_base = view.dragSnapshot();
        try self.requestDrag();
        // The release is waited for by the payload free it causes. Every
        // terminal path of a drag frees the payload exactly once, so this ends
        // when THIS release has been routed — and not before, which a routed
        // count could do while the release was still in the queue.
        try self.awaitCounter(&view.payload_frees, self.drag_base.frees, 1);
        try self.pump();

        const snapshot = try self.emitDrag("refuse", self.drag_base);
        try self.expect(snapshot.checks == 1, error.RefusedDropDidNotAskTheTarget);
        try self.expect(snapshot.cancels == 1, error.RefusedDropDidNotCancel);
        try self.expect(snapshot.drops == 0, error.RefusedDropCommitted);
        try self.expect(snapshot.frees == 1, error.RefusedDropDidNotFreeOnce);
        try self.expect(view.dropped_len == 0, error.RefusedDropChangedTheModel);
        try self.expect(view.card_clicks == 0, error.RefusedDropCameFromACardClick);
        try self.emit(
            "STEP refuse OK checks={d} cancels={d} drops={d} frees={d} card_clicks={d}\n",
            .{ snapshot.checks, snapshot.cancels, snapshot.drops, snapshot.frees, view.card_clicks },
        );
    }

    // ── step 11: and one it accepts ───────────────────────────────────

    fn stepAccept(self: *Self) !void {
        const view = self.scenario.view;
        view.accept_drops = true;
        self.drag_base = view.dragSnapshot();
        try self.requestDrag();
        try self.awaitCounter(&view.payload_frees, self.drag_base.frees, 1);
        try self.pump();

        const snapshot = try self.emitDrag("accept", self.drag_base);
        try self.expect(snapshot.drops == 1, error.AcceptedDropDidNotCommitOnce);
        try self.expect(snapshot.cancels == 0, error.AcceptedDropAlsoCancelled);
        try self.expect(snapshot.frees == 1, error.AcceptedDropDidNotFreeOnce);
        try self.expect(std.mem.eql(u8, "notes", view.droppedTitle()), error.AcceptedTitleIsNotThePayload);
        try self.expect(view.card_clicks == 0, error.AcceptedDropCameFromACardClick);
        // Three drags, three destructions and one refused wrong-typed read
        // each: no leak and no double free.
        try self.expect(view.payload_frees == 3, error.PayloadFreeCount);
        try self.expect(view.foreign_reads == 3, error.ForeignReadCount);
        try self.emit(
            "STEP accept OK drops={d} cancels={d} frees={d} title='{s}' payload_frees={d} foreign_reads={d}\n",
            .{
                snapshot.drops,      snapshot.cancels,   snapshot.frees,
                view.droppedTitle(), view.payload_frees, view.foreign_reads,
            },
        );
    }

    // ── step 12: leaving and re-entering re-arms the delay ────────────

    fn stepTipLeave(self: *Self) !void {
        const view = self.scenario.view;
        const hint = try self.scenario.centreOf(key_hint);
        const drop = try self.scenario.centreOf(key_drop);
        const arms = view.tip_arms;
        var moves = view.pointer_moves;

        // Every motion here is a REAL transition, and the step puts each one in
        // place instead of assuming it. The pointer arrives wherever the last
        // drag's release left it, and a request naming the position the pointer
        // is ALREADY at moves nothing: the platform delivers no motion at all,
        // so waiting for one waits forever for an event that cannot exist. The
        // drag that precedes this step ends its release on menu-drop, which is
        // exactly where this step's leave asks to go. So the step first walks
        // the pointer back ONTO the hint — a real move, and a real arm — and
        // every claim below is then about the leave that follows it and the
        // re-entry that follows the leave. Alternating the two points is what
        // makes each move a transition whichever of them the pointer was on.
        try self.request(
            "xdotool mousemove --sync --window {d} {d:.0} {d:.0}  # ONTO the hint, so the leave below is a real transition",
            .{ self.window(), hint[0], hint[1] },
        );
        try self.awaitCounter(&view.pointer_moves, moves, 1);
        try self.awaitCounter(&view.tip_arms, arms, 1);
        try self.awaitTrue(&tooltipArmed);
        try self.pump();
        // The deadline this step's leave is about to cancel. The re-arm is
        // claimed against THIS arm rather than against the first of the run, so
        // the comparison names the move it actually replaced.
        const armed_ns = view.tip.deadline().?.at_ns;

        // Read AFTER the arm above, so "the leave delivered nothing" is a claim
        // about the leave and not about an arm this step made on its way here.
        const before = try self.scenario.tipStats();
        moves = view.pointer_moves;
        try self.request(
            "xdotool mousemove --sync --window {d} {d:.0} {d:.0}  # LEAVE the hint, onto menu-drop",
            .{ self.window(), drop[0], drop[1] },
        );
        try self.awaitCounter(&view.pointer_moves, moves, 1);
        try self.awaitTrue(&tooltipIdle);
        try self.pump();
        const after_leave = try self.scenario.tipStats();
        try self.expect(
            after_leave.delivered == before.delivered,
            error.LeaveDeliveredATimer,
        );

        moves = view.pointer_moves;
        try self.request(
            "xdotool mousemove --sync --window {d} {d:.0} {d:.0}  # RE-ENTER the hint",
            .{ self.window(), hint[0], hint[1] },
        );
        try self.awaitCounter(&view.pointer_moves, moves, 1);
        try self.awaitCounter(&view.tip_arms, arms + 1, 1);
        try self.awaitTrue(&tooltipArmed);
        try self.pump();

        const deadline = view.tip.deadline().?;
        self.reenter_deadline_ns = deadline.at_ns;
        try self.expect(deadline.at_ns > armed_ns, error.ReenterDidNotRearmLater);
        try self.expect(view.tip_cancels >= 1, error.ReenterDidNotCancelTheStaleJob);
        try self.expect(!view.tip.visible(), error.ReenterShowedTheTooltipEarly);
        try self.emit(
            "STEP tip-leave OK first_in={d}ms left_at={d}ms rearmed_in={d}ms arms={d} cancels={d} leave_delivered={d}\n",
            .{
                @divTrunc(self.first_deadline_ns - self.scenario.clock.now(), std.time.ns_per_ms),
                @divTrunc(armed_ns - self.scenario.clock.now(), std.time.ns_per_ms),
                @divTrunc(deadline.at_ns - self.scenario.clock.now(), std.time.ns_per_ms),
                view.tip_arms,
                view.tip_cancels,
                after_leave.delivered - before.delivered,
            },
        );
    }

    // ── step 13: a retired owner takes its pending timer with it ──────

    fn stepTipRemove(self: *Self) !void {
        const view = self.scenario.view;
        const hint = view.widget(key_hint) orelse return error.MissingHint;
        // The owner leaves the tree, which is a model change this consumer
        // makes; the TIMER it left behind is the engine's to cancel.
        view.show_hint = false;
        try self.pump();
        try self.expect(view.tip.deadline() == null, error.RetiredOwnerKeptItsDeadline);
        try self.expect(view.tip.descriptionFor(hint) == null, error.RetiredOwnerKeptItsDescription);
        try self.expect(view.tip_cancels >= 1, error.RetiredOwnerDidNotCancelItsJob);
        // Read AFTER the retirement above. The claim below is about the timer
        // the RETIRED owner left behind, so it is measured from the instant
        // that owner was gone. An arm the previous step left pending cannot
        // reach this count, and a delivery that arm produced is not this step's
        // failure — the step judges the retired owner's own timer, nothing else.
        const before = try self.scenario.tipStats();

        // Past the deadline the retired owner had, in REAL time: the pending
        // job is either cancelled or delivered with a token no longer in
        // force. Either way it must not show a tooltip.
        const settle_ms = hint_delay_ns / std.time.ns_per_ms * 2 + 50;
        var waited: u64 = 0;
        while (waited < settle_ms) : (waited += 10) {
            _ = try self.application.step();
            try std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(10), .real);
        }
        try self.pump();
        const after = try self.scenario.tipStats();
        try self.expect(after.delivered == before.delivered, error.StaleTimerDelivered);
        try self.expect(!view.tip.visible(), error.StaleTimerShowedATooltip);
        try self.emit(
            "STEP tip-remove OK deliveries={d} visible=false deadline=null waited_ms={d}\n",
            .{ after.delivered - before.delivered, waited },
        );
    }

    // ── step 14: the item is reached at its PAINTED position ───────────

    fn stepReopen(self: *Self) !void {
        const view = self.scenario.view;
        view.show_hint = true;
        try self.pump();
        try self.expect(view.widget(key_hint) != null, error.HintDidNotReturn);
        try self.expect(!view.tip.visible(), error.TooltipVisibleBeforeTheItemClick);

        const file = try self.scenario.centreOf(key_file);
        const opens = view.menu_opens;
        try self.request(
            "xdotool mousemove --sync --window {d} {d:.0} {d:.0} click 1  # reopen the menu",
            .{ self.window(), file[0], file[1] },
        );
        try self.awaitCounter(&view.menu_opens, opens, 1);
        try self.pump();
        // The wait above only bounds the arrival. This is the claim: one
        // request, one click, one activation — the same exactness step two
        // checks on the very first click of the run.
        try self.expect(view.menu_opens == opens + 1, error.ReopenCountedMoreThanOneOpen);

        const menu = try self.menuRect();
        const item_point: [2]f32 = .{ menu.x + menu.w / 2, menu.y + 10 };
        // The engine's own resolution names the item there; the raw layout-box
        // walk is printed beside it so the two answers are comparable.
        const picks = self.scenario.picksAt(item_point);
        try self.expect(picks.placed == 'o', error.PlacedPickIsNotTheItem);

        const items = view.item_clicks;
        try self.request(
            "xdotool mousemove --sync --window {d} {d:.0} {d:.0} click 1  # PAINTED position of menu-item inside the placed menu",
            .{ self.window(), item_point[0], item_point[1] },
        );
        try self.awaitCounter(&view.item_clicks, items, 1);
        try self.pump();
        try self.expect(view.item_clicks == items + 1, error.ItemClickDidNotActivateTheItem);
        try self.expect(view.card_clicks == 0, error.ItemClickReachedTheCoveredCard);
        // A menu item dismisses the menu, and the scope hands focus back.
        try self.expect(!view.open_menu, error.ItemDidNotCloseTheMenu);
        try self.expect(view.focus_restores == 2, error.ItemCloseDidNotRestoreFocus);
        try self.emit(
            "STEP reopen OK point={d:.0},{d:.0} raw_pick='{c}' placed_pick='{c}' item_clicks={d} card_clicks={d}\n",
            .{ item_point[0], item_point[1], picks.raw, picks.placed, view.item_clicks, view.card_clicks },
        );
    }

    // ── step 15: the closing frame, with both popups placed and painted ─

    fn stepClosing(self: *Self) !void {
        const view = self.scenario.view;
        const file = try self.scenario.centreOf(key_file);
        const opens = view.menu_opens;
        try self.request(
            "xdotool mousemove --sync --window {d} {d:.0} {d:.0} click 1  # open the menu before hovering the hint",
            .{ self.window(), file[0], file[1] },
        );
        try self.awaitCounter(&view.menu_opens, opens, 1);
        const hint = try self.scenario.centreOf(key_hint);
        const arms = view.tip_arms;
        try self.request(
            "xdotool mousemove --sync --window {d} {d:.0} {d:.0}  # hover the hint for the closing frame",
            .{ self.window(), hint[0], hint[1] },
        );
        try self.awaitCounter(&view.tip_arms, arms, 1);
        try self.awaitTrue(&tipShown);
        try self.pump();

        try self.expect(view.open_menu, error.ClosingFrameHasNoMenu);
        try self.expect(view.menu_opens == opens + 1, error.ClosingCountedMoreThanOneOpen);
        try self.expect(view.tip.visible(), error.ClosingFrameHasNoTooltip);
        const menu = try self.menuRect();
        const tip = try self.tipRect();
        const shared = overlapRect(menu, tip) orelse return error.OverlaysDoNotOverlap;
        const band = menuOnlyBand(menu, tip);
        const shared_px = self.census(shared);
        const band_px = self.census(band);
        const canvas = self.census(backgroundRect());
        try self.expect(shared_px.tip > 0, error.ClosingOverlapIsNotTheTooltip);
        try self.expect(shared_px.menu == 0, error.ClosingOverlapStillShowsTheMenu);
        try self.expect(band_px.menu > 0, error.ClosingMenuDidNotPaintItsFill);
        try self.expect(band_px.tip == 0, error.ClosingTooltipPaintedOutsideItsBox);
        try self.expect(canvas.total > 0, error.CannotProbeTheClosingCanvas);
        try self.expect(canvas.clear == canvas.total, error.ClosingCanvasIsNotTheOklabClear);

        try self.emit(
            "STEP closing OK menu={d:.0},{d:.0} {d:.0}x{d:.0} tip={d:.0},{d:.0} {d:.0}x{d:.0} overlap_tip_px={d} overlap_menu_px={d} band_menu_px={d} canvas_clear={d}\n",
            .{
                menu.x,        menu.y,         menu.w,       menu.h,
                tip.x,         tip.y,          tip.w,        tip.h,
                shared_px.tip, shared_px.menu, band_px.menu, canvas.clear,
            },
        );
    }
};

/// The card holds the pointer: the press really captured it. This is what a
/// press is waited for by, in preference to a routed count that also moves for
/// the focus and activation dispatches that same press produces.
fn dragCaptured(view: *MenuView) bool {
    const tree = view.app.tree_ptr orelse return false;
    return view.app.focus_manager.captured(tree, .{ .mouse = .left }, null) != null;
}

/// Drive the scenario and print the deterministic result. The default is the
/// headless specimen: no window, no SDL, no shader file, no display. With
/// `--native` the same scene is mounted on a real owned toplevel and every
/// step it takes is reported on stdout, one line per step.
pub fn main(init: std.process.Init) !void {
    var gpa_state: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var options = try parseArgs(init, gpa);
    defer options.deinit(gpa);

    // The Io the device, the shader files, the bounded waits and the report
    // stream all share. It is registered first so it outlives the window's
    // close — the one moment the device stack may be released — and the last
    // line this run writes.
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();

    // The headless scenario runs on an injected clock this process owns, which
    // is what keeps the default run deterministic and sleep-free. The native
    // scenario runs on the PRODUCTION monotonic clock, because a tooltip
    // deadline nobody advances is a deadline that has to arrive on its own.
    const scenario = if (options.native)
        try Scenario.initWithClock(gpa, nogui.Clock.monotonic(threaded.io()))
    else
        try Scenario.init(gpa);
    defer scenario.deinit();

    if (options.native) {
        // Declared in place and never moved: the adapter holds addresses into
        // itself, and this storage must outlive the window's close, because
        // the host's `on_before_close` hook is what releases the device stack
        // while the native window is still alive.
        var native: Native = undefined;
        try native.init(gpa, threaded.io(), scenario, options);
        // Deliberately no `defer native.deinit()`: `scenario.deinit` closes
        // the window, and that close is what releases the adapter, the
        // surface, the device and the loader, in that order and in the window.
        try native.run();
        return;
    }

    try specimen(scenario, true);

    std.debug.print("\ncommitted tree, windowless raster (4x8 px per cell):\n", .{});
    std.debug.print("  F file  ? hint  A anchor  C card  D drop  M menu  o item  T tooltip\n", .{});
    const rows = scenario.raster();
    for (rows) |row| {
        std.debug.print("  {s}\n", .{&row});
    }

    // What this run did NOT do, stated rather than implied.
    std.debug.print(
        \\
        \\popup limit, in BOTH arms: the menu and the tooltip are in-window
        \\overlay subtrees, not OS popups. A real popup needs
        \\window_contract.Kind.{s} with a parent WindowHandle, which only a live
        \\host window can own; this file owns none. `--native` puts the same
        \\subtrees on a real window and reads the pixels back, which is a
        \\different proof and not a different popup.
        \\
    , .{@tagName(window_contract.Kind.menu)});
    std.debug.print(
        "pick limit: the raw layout-box pick and the placed pick are printed together above;\n" ++
            "where they differ, the consumer's placed answer is the one that names the popup\n",
        .{},
    );
    std.debug.print(
        "run `--native` for the same sequence on a real window, through SDL input and a GPU readback\n",
        .{},
    );
}

// --- tests -----------------------------------------------------------------

test "api-w16 mounted popup, routed drag and W05 tooltip on one real App" {
    var gpa_state: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    defer std.testing.expect(gpa_state.deinit() == 0) catch {};
    const gpa = gpa_state.allocator();

    var scenario = try Scenario.init(gpa);
    defer scenario.deinit();
    try specimen(scenario, false);

    const view = scenario.view;

    // ── every observation below is a model value a routed handler wrote ──
    try std.testing.expect(view.routed > 0);
    try std.testing.expectEqual(@as(u32, 3), view.file_clicks);
    // Three routed clicks opened the menu, and the escape and the item each
    // retired one. The last open is still up, holding the closing frame's
    // placement for the raster.
    try std.testing.expectEqual(@as(u32, 3), view.menu_opens);
    try std.testing.expectEqual(@as(u32, 2), view.menu_closes);
    // Each close handed a live target back, so focus never fell to a blur.
    try std.testing.expectEqual(@as(u32, 2), view.focus_restores);
    try std.testing.expect(view.focus_changes > 0);

    // The popup was placed under its anchor, inside the viewport, and its
    // window-escape policy really released the scroller's clip.
    try std.testing.expect(view.menu_placement.w > 0 and view.menu_placement.h > 0);
    try std.testing.expect(view.menu_placement.x >= 0);
    try std.testing.expect(view.menu_placement.y >= 0);
    try std.testing.expect(view.menu_placement.x + view.menu_placement.w <= surface.width);
    try std.testing.expect(view.menu_placement.y + view.menu_placement.h <= surface.height);
    try std.testing.expect(view.menu_escaped_clip);

    // A real wheel event over the anchor scrolled the container, and the popup
    // moved by exactly the scroll delta: the placement is read from the current
    // visual geometry, not from the previous frame.
    try std.testing.expect(view.scroll_offset > 0);
    try std.testing.expectApproxEqAbs(@as(f32, -20), view.scrolled_by, 0.01);

    // The menu item was reached at its PAINTED position through the placed
    // seam. The raw layout-box walk answers something else there, which is why
    // the consumer's own resolution is the one that matters.
    try std.testing.expectEqual(@as(u8, 'o'), view.placed_pick_glyph);
    try std.testing.expectEqual(@as(u32, 1), view.item_clicks);
    // The overlay shadowed the control it covered: the card underneath was
    // never pressed or activated by the click that belonged to the item.
    try std.testing.expectEqual(@as(u32, 0), view.card_clicks);

    // Escape closed the menu and returned focus to the surviving prior target.
    try std.testing.expectEqual(view.widget(key_file).?, view.focus_after_escape.?);
    try std.testing.expect(view.focus_after_escape != null);
    try std.testing.expectEqual(view.widget(key_item).?, view.focus_after_open.?);

    // The tooltip's delay lived in the W05 service, at the instant the
    // consumer handed it, and nothing showed before it.
    try std.testing.expect(view.tip_deadline_ns > 0);
    try std.testing.expectEqual(view.tip_deadline_ns, view.service_deadline_ns);
    try std.testing.expect(view.tip_pending_early);
    try std.testing.expectEqual(@as(u32, 1), view.arms_at_show);
    try std.testing.expectEqual(@as(u32, 1), view.tip_at_show.delivered);
    try std.testing.expectEqual(@as(u32, 1), view.tip_at_show.fired);
    try std.testing.expect(view.tip_at_show.visible);
    try std.testing.expect(view.tip_shows >= 1);
    try std.testing.expect(view.tip_bounds_set);

    // Paint order and hit precedence come from one key, and the topmost
    // painted overlay owns the overlapping point. The layers compared are the
    // ones the painter emits, and the run failed above on any disagreement
    // between them rather than on a named constant.
    try std.testing.expect(view.tip_paints_above);
    try std.testing.expect(view.overlap_point != null);
    try std.testing.expectEqual(@as(u8, 'T'), view.overlap_winner);

    // A move under the threshold is not a drag.
    try std.testing.expectEqual(@as(u32, 1), view.under_threshold_moves);

    // The pointer leaving the window cancelled the drag through the engine's
    // own capture revocation: the target left, the source was cancelled, the
    // payload died once, and nothing committed.
    try std.testing.expectEqual(@as(u32, 1), view.outside_cancels);
    try std.testing.expectEqual(@as(u32, 1), view.outside_cancel.enters);
    try std.testing.expectEqual(@as(u32, 1), view.outside_cancel.leaves);
    try std.testing.expectEqual(@as(u32, 1), view.outside_cancel.cancels);
    try std.testing.expectEqual(@as(u32, 0), view.outside_cancel.checks);
    try std.testing.expectEqual(@as(u32, 0), view.outside_cancel.drops);
    try std.testing.expectEqual(@as(u32, 1), view.outside_cancel.frees);

    // A refusing target ran the cancel path, not the commit path: one check,
    // ONE cancellation of this drag's own rather than the run's total, no
    // commit, and the payload died exactly once.
    try std.testing.expectEqual(@as(u32, 1), view.refused.checks);
    try std.testing.expectEqual(@as(u32, 1), view.refused.cancels);
    try std.testing.expectEqual(@as(u32, 0), view.refused.drops);
    try std.testing.expectEqual(@as(u32, 1), view.refused.frees);

    // An accepting target committed exactly once and cancelled not at all.
    try std.testing.expectEqual(@as(u32, 1), view.accepted.drops);
    try std.testing.expectEqual(@as(u32, 0), view.accepted.cancels);
    // Three drags, three destructions and one refused wrong-typed read per
    // drag: no leak and no double free.
    try std.testing.expectEqual(@as(u32, 3), view.payload_frees);
    try std.testing.expectEqual(@as(u32, 3), view.foreign_reads);
    try std.testing.expectEqualStrings("notes", view.droppedTitle());
    // The accepted drop came from the drag release, not from a stray click on
    // the card underneath it.
    try std.testing.expectEqual(@as(u32, 0), view.accepted.card_clicks);
    // A move callback routed while the pointer stayed over a target, so a
    // drag was live for more than its single release.
    try std.testing.expect(view.drag_moves >= 1);
    // The run ends with the menu open, so the focus the observer last saw is
    // the menu's focus scope, not a blur and not the covered card.
    try std.testing.expectEqual(view.widget(key_item).?, view.focus_current.?);

    // Leaving and re-entering respects the delay: the second hover armed a
    // later deadline, and the cancelled job delivered nothing.
    try std.testing.expect(view.reenter_deadline_ns > view.tip_deadline_ns);
    try std.testing.expectEqual(@as(u32, 2), view.arms_at_reenter);
    try std.testing.expect(view.cancels_at_reenter >= 1);
    // A retired owner took its pending W05 timer with it: the handler never
    // ran for the deadline that outlived the widget.
    try std.testing.expectEqual(@as(u32, 0), view.retire_deliveries);
    try std.testing.expect(!view.retire_visible);
}

test "api-w25 overlay hit order, refused drop, and a disappearing tooltip owner" {
    var gpa_state: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    defer std.testing.expect(gpa_state.deinit() == 0) catch {};
    const gpa = gpa_state.allocator();

    var scenario = try Scenario.init(gpa);
    defer scenario.deinit();
    _ = try scenario.publish(1);
    const view = scenario.view;

    // Open the menu through a real routed click, then resolve an overlay frame
    // over the tree the App committed.
    try scenario.click(try scenario.centreOf(key_file));
    _ = try scenario.publish(2);
    const tree = try scenario.liveTree();
    const menu_content = view.widget(key_menu).?;
    const menu_node = tree.frameNode(menu_content) orelse return error.MissingMenuContent;

    var frame = overlay.Frame.init(gpa);
    defer frame.deinit();
    try frame.add(.{
        .anchor = view.widget(key_anchor).?,
        .content = menu_content,
        .side = .below,
        .gap = 2,
        .clip = .window_escape,
        .priority = 1,
    });
    // A second record for the same content is refused rather than painting one
    // subtree twice.
    try std.testing.expectError(error.DuplicateContent, frame.add(.{
        .anchor = view.widget(key_anchor).?,
        .content = menu_content,
        .priority = 9,
    }));
    try frame.resolve(tree, overlay_viewport);
    // The refused duplicate never reached the resolution: one content root, one
    // placement.
    const records = frame.records(tree) orelse return error.UnplacedRecords;
    try std.testing.expectEqual(@as(usize, 1), records.len);
    const placement = frame.placement(tree, menu_content) orelse return error.UnplacedMenu;
    try std.testing.expect(placement.rect.w > 0 and placement.rect.h > 0);
    try std.testing.expect(placement.rect.y >= 0);

    // The point inside the placed overlay resolves to that overlay, and to the
    // consumer's own hit resolution, through the public parent chain.
    const point: [2]f32 = .{
        placement.rect.x + placement.rect.w / 2,
        placement.rect.y + 10,
    };
    const hit = frame.hitTest(tree, point) orelse return error.MissedOverlay;
    try std.testing.expect(withinSubtree(tree, hit, menu_node));
    try std.testing.expectEqual(view.widget(key_item).?, stableAncestor(tree, hit));

    // The band and the clip come from the same record the hit test used. The
    // layer compared is the one the PAINTER emits, and it is compared against
    // the highest layer the application itself authors: an overlay paints
    // above the application because the frame raised its band above that
    // maximum, not because of a constant this test chose.
    const menu_paint = tree.nodeConst(menu_node) orelse return error.MissingMenuPaint;
    const menu_band = menu_paint.placement_paint orelse return error.MissingMenuBand;
    try std.testing.expect(
        try widget.effectiveLayer(menu_paint, 0) > try widget.maximumPaintLayer(tree),
    );
    // The control inside the overlay travels in the same band, so it paints
    // with the popup and not with the content it covers.
    const item_node = tree.frameNode(view.widget(key_item).?) orelse return error.MissingItem;
    const item_paint = tree.nodeConst(item_node) orelse return error.MissingItemPaint;
    const item_band = item_paint.placement_paint orelse return error.MissingItemBand;
    try std.testing.expectEqual(menu_band.record_index, item_band.record_index);
    try std.testing.expectEqual(menu_band.layer, item_band.layer);
    try std.testing.expect(
        try widget.effectiveLayer(item_paint, 0) >= try widget.effectiveLayer(menu_paint, 0),
    );
    try std.testing.expectEqual(@as(?widget.ClipRect, null), tree.node(menu_node).?.placement_clip);
    try std.testing.expect(frame.isOverlayNode(tree, menu_node));

    // A refused release runs the cancel path, not the commit path, and the
    // payload dies exactly once.
    view.accept_drops = false;
    try scenario.drag(
        try scenario.centreOf(key_card),
        try scenario.centreOf(key_drop),
        2,
    );
    try std.testing.expectEqual(@as(u32, 1), view.drag_checks);
    try std.testing.expectEqual(@as(u32, 1), view.drag_cancels);
    try std.testing.expectEqual(@as(u32, 0), view.drops);
    try std.testing.expectEqual(@as(u32, 1), view.payload_frees);
    try std.testing.expectEqual(@as(u32, 0), view.card_clicks);

    // A tooltip whose owner leaves the tree loses its pending deadline, so the
    // already-scheduled W05 callback can never show it.
    scenario.ticks.value = 9_000;
    const hint = view.widget(key_hint).?;
    try scenario.move(try scenario.centreOf(key_hint), false);
    const armed = view.tip.deadline() orelse return error.MissingTooltipDeadline;
    try std.testing.expect(view.tip_handle != null);
    // The keyboard/semantic description exists during the delay, not only
    // after the tooltip paints.
    try std.testing.expectEqualStrings(hint_description, view.tip.descriptionFor(hint).?);
    view.show_hint = false;
    _ = try scenario.publish(3);
    try std.testing.expect(view.tip.deadline() == null);
    try std.testing.expect(view.tip.descriptionFor(hint) == null);
    // Even if the stale timer fires with the old token, nothing appears.
    scenario.ticks.value = armed.at_ns + 1;
    _ = try scenario.drain();
    try std.testing.expect(!view.tip.visible());
    try std.testing.expectEqual(@as(u32, 0), view.tip_shows);
    try std.testing.expect(view.tip_cancels >= 1);
}

test "api-w25 menu enablement follows the focused context through the action bridge" {
    var gpa_state: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    defer std.testing.expect(gpa_state.deinit() == 0) catch {};
    const gpa = gpa_state.allocator();

    var scenario = try Scenario.init(gpa);
    defer scenario.deinit();
    _ = try scenario.publish(1);
    const tree = try scenario.liveTree();
    const view = scenario.view;

    const card = view.widget(key_card).?;
    const hint = view.widget(key_hint).?;

    _ = try scenario.registry.bind(
        UndoAction,
        Editor,
        Editor.undo,
        Editor.undoAvailable,
        .{ .widget = card },
        scenario.editor.weak(),
    );
    _ = try scenario.registry.bind(
        RedoAction,
        Editor,
        Editor.redo,
        Editor.redoAvailable,
        .{ .widget = card },
        scenario.editor.weak(),
    );
    _ = try scenario.registry.bind(
        MinimizeAction,
        Editor,
        Editor.minimize,
        Editor.minimizeAvailable,
        .{ .widget = card },
        scenario.editor.weak(),
    );

    const items = [_]menus.MenuItem{
        .{ .id = 1, .label = "Undo", .kind = .action, .action_name = "edit.undo" },
        .{ .id = 2, .label = "Redo", .kind = .action, .action_name = "edit.redo" },
        .{ .id = 3, .label = "Minimize", .kind = .system_action, .system_action = .minimize },
        .{ .id = 4, .label = "-", .kind = .separator },
    };
    const bar: menus.MenuBar = .{ .menus = &.{
        .{ .title = "Edit", .items = &items },
    } };
    var bridge = menus.MenuActionBridge.init(&scenario.registry);

    // Focused on the editor: Undo is available, Redo is disabled, and the
    // system row is live because this context owns its binding.
    var on_card = try bridge.evaluate(gpa, bar, tree, card);
    defer on_card.deinit();
    try std.testing.expect(on_card.menus[0].items[0].enabled);
    try std.testing.expect(!on_card.menus[0].items[1].enabled);
    try std.testing.expect(on_card.menus[0].items[2].enabled);
    // A separator is a divider, never a clickable item.
    try std.testing.expect(!on_card.menus[0].items[3].enabled);

    // Focused elsewhere: the same Undo item and the same system row are now
    // unavailable, because their bindings do not match the focused context.
    var on_hint = try bridge.evaluate(gpa, bar, tree, hint);
    defer on_hint.deinit();
    try std.testing.expect(!on_hint.menus[0].items[0].enabled);
    try std.testing.expect(!on_hint.menus[0].items[2].enabled);

    // Changing the model flips enablement on the next evaluation, with no
    // rebuild of the menu.
    try scenario.session.update(Editor, scenario.editor, {}, struct {
        fn apply(editor: *Editor, _: void) !void {
            editor.can_undo = false;
            editor.can_redo = true;
        }
    }.apply);
    var after = try bridge.evaluate(gpa, bar, tree, card);
    defer after.deinit();
    try std.testing.expect(!after.menus[0].items[0].enabled);
    try std.testing.expect(after.menus[0].items[1].enabled);

    // Dispatching Undo now reports it as disabled rather than a fake success.
    try std.testing.expectEqual(
        action.Result.disabled,
        try scenario.registry.dispatch(tree, card, "edit.undo", null),
    );
    // Redo dispatches cleanly through the same bridge.
    try std.testing.expectEqual(
        action.Result.handled,
        try bridge.dispatchItem(items[1], tree, card),
    );
    // An unknown action name is an error, not a silent no-op.
    try std.testing.expectError(
        error.UnknownAction,
        scenario.registry.dispatch(tree, card, "edit.nope", null),
    );
}
