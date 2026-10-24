//! One `Session` model, two `App` windows, two independent frame pipelines.
//!
//! This is the shape every multi-window nogui application has:
//!
//!   * A single `Session` owns the model. Neither `App` stores its bytes.
//!   * Each window calls `App.mountModelRoot`, so each `App` holds its OWN
//!     retained ticket. The caller keeps the strong owner and releases it once.
//!   * `Session.update` is the only writer. Both windows are invalidated by it,
//!     each takes its own redraw, and each publishes its own frame.
//!   * The two views are *not* interchangeable: each `App` owns a pair of frame
//!     arenas and its own `IdentityRegistry`, so the same logical widget in two
//!     windows is two different `WidgetId`s that never cross over.
//!
//! THREE ARMS, and they do not claim the same thing:
//!
//!   * DEFAULT (no flag): the public headless `App` driver, and then the same
//!     scenario inside a real `nogui_host.Application` on SDL's `dummy` video
//!     driver. The dummy arm commits REAL host windows and routes REAL SDL
//!     events, but it has no display server, NO GPU and NO PRESENTATION: its
//!     frames are CPU trees. It is labelled `dummy` everywhere, including its
//!     record, and it is never reported as native.
//!   * `--native`: the same two Apps inside the same host, with frames
//!     PRESENTED by one `v7_frame.NativeFrame` per window over
//!     `noapi.Surface.initSdl` into that window's swapchain image, with a
//!     pinned real face measuring, shaping and rasterizing every label. Each
//!     window reports the extent, the pixel scale, the swapchain retries and
//!     the presentation count the platform and the frame module actually
//!     answered. Both windows' readbacks are checked for ink and against each
//!     other, so two windows showing one window's pixels twice is a refusal.
//!
//! The hosted arms read input from SDL's own queue and let the host route it,
//! and THOSE EVENTS ARE SYNTHETIC: they are pushed onto the queue by this
//! file, not read from a physical pointer, and nothing here is real IME or an
//! external keyboard acceptance. The pushed pointer position is a LOGICAL
//! window point, which is the unit the host hands an App. This scenario
//! registers no text endpoint, so no text-input path runs; it never calls a
//! clipboard port (the host binds one to each window at open, and nothing
//! here reaches it); and no accessibility bus is attached: the semantic
//! publishers below are plain in-process snapshots.
//!
//! Run it: `zig build run-parity-shared-model` for the default pair, and
//! `zig build run-parity-shared-model-native -- <vert.spv> <frag.spv> <sort.spv>`
//! for the presented arm. `--ppm PATH` / `--ppm-right PATH` write each
//! window's last presented frame as a P6 PPM, and `--fullscreen-vert PATH` /
//! `--blit-oklab PATH` name the two blit modules the native arm records with.
const std = @import("std");

const nogui = @import("nogui");
const host = @import("nogui_host");
const sdl3 = @import("sdl3");
const v7_frame = @import("v7_frame");
/// The pinned real face every presented label is measured, shaped and
/// rasterized with. The build wires this anonymous module to the same
/// `InterVariable.ttf` the other presented parity examples embed, so nothing
/// here names a font path and no private demo asset is reached.
const font_bytes = @import("font_bytes").bytes;

const noapi = v7_frame.noapi;
const scene = v7_frame.scene;
const Session = nogui.Session;
const App = nogui.App;
const DrawCtx = nogui.DrawCtx;
const semantics = nogui.semantics;
const contract = nogui.window_contract;

/// One logical window size. The two windowless arms lay out at it, so a
/// semantic snapshot describes the same surface in either run.
const surface: nogui.Size = .{ .width = 240, .height = 120 };

/// The size the PRESENTED arm asks each window for. A window may answer with
/// something else — a compositor is free to clamp or scale — so the presented
/// run lays out in what it OBSERVED and records that, never in this number.
const window_authored: contract.Size = .{ .width = 360, .height = 220 };

/// Host event batches spent waiting for a window to take its geometry and
/// show, then holding a presented frame, and then retrying an acquire whose
/// swapchain was out of date. Bounds, not timeouts.
const readiness_polls: u32 = 32;
const hold_polls: u32 = 8;
const poll_delay_ms: i64 = 20;
const acquire_polls: u32 = 8;

/// How long a shutdown waits for worker-owned payloads before the Session is
/// allowed to refuse and keep them alive. The native host unregisters its task
/// wake first, so this is the bound the tasks themselves are held to.
const task_shutdown_ns: u64 = 2_000 * std.time.ns_per_ms;

const app_id: [:0]const u8 = "dev.nogui.examples.parity.shared-model";
const window_title_left: [:0]const u8 = "nogui shared model left";
const window_title_right: [:0]const u8 = "nogui shared model right";

/// The one keyed control each pane publishes. Both windows author the SAME
/// key, and the identity registries are per-App, so the two resolved ids are
/// unrelated: that is the claim the identity checks below hold to.
const key_header: nogui.ComponentKey = .{ .static = "header" };

/// The shared document. The two windows are two readers of this one value.
pub const Document = struct {
    title: []const u8 = "notes",
    revision: u32 = 1,

    pub fn deinit(self: *Document, _: *Session) void {
        // Nothing owned yet; a real document would free its text buffer here.
        _ = self;
    }
};

/// One window's view. `draw` receives the model already borrowed read-only.
pub const Pane = struct {
    const Self = @This();

    /// Which window this pane belongs to; only used to label the output.
    name: []const u8,
    /// The revision this pane last observed. A real pane repaints from it.
    observed: u32 = 0,
    /// Header activations that stayed local to this pane's window.
    clicks: u32 = 0,

    pub fn draw(self: *Self, doc: *const Document, ctx: *DrawCtx) !void {
        self.observed = doc.revision;
        // The text is allocated from THIS App's frame arena and dies with it.
        const text = try std.fmt.allocPrint(ctx.arena, "{s} r{d}", .{ self.name, doc.revision });
        _ = try ctx.label(.{ .text = text });
        // A keyed button gives the window a stable WidgetId to hit-test, focus,
        // scroll to, or attach a text endpoint to.
        _ = try ctx.button(.{
            .key = key_header,
            .label = "header",
            .on_click = Self.onHeader,
        });
    }

    fn onHeader(self: *Self) void {
        self.clicks += 1; // a local, non-model mutation
    }
};

/// The one and only writer. `Session.update` is the whole write path.
const Bump = struct {
    fn apply(doc: *Document, _: void) !void {
        doc.revision += 1;
    }
};

/// The document's other field, written through the same one writer. It does
/// not move the revision, so a run that let it disturb the revision would
/// change the label both windows paint.
const Rename = struct {
    fn apply(doc: *Document, title: []const u8) !void {
        doc.title = title;
    }
};

/// The label a committed tree holds for its first text node.
pub fn firstLabel(tree: *const nogui.WidgetTree) ?[]const u8 {
    for (tree.nodes.items) |node| {
        switch (node.kind) {
            .label => |label| return label.text,
            else => {},
        }
    }
    return null;
}

/// Read the model without retaining the pointer. The text is copied out of the
/// borrow so the caller owns a stable slice.
const ReadRevision = struct {
    revision: u32 = 0,
    fn read(doc: *const Document, out: *ReadRevision) void {
        out.revision = doc.revision;
    }
};

/// One window's observable result. Every arm fills this from its own committed
/// tree and its own published snapshot, so the comparison is a value
/// comparison and not a re-derivation.
pub const WindowReport = struct {
    /// The label the window painted from the shared model.
    label: [16]u8 = undefined,
    label_len: usize = 0,
    /// The revision this window's pane last drew.
    observed: u32 = 0,
    /// Header activations this window's own pane received.
    clicks: u32 = 0,
    /// A semantic snapshot was published and carries a window root.
    published_nodes: usize = 0,
    /// The header button is a published, focusable, clickable node.
    header_role: u8 = 0,
    /// The header's accessible name, copied out of the snapshot while that
    /// snapshot is still the live one.
    header_name: [16]u8 = undefined,
    header_name_len: usize = 0,
    header_focusable: bool = false,
    header_clickable: bool = false,
    header_focused: bool = false,
    /// The committed keyboard focus is the header.
    focus_is_header: bool = false,

    pub fn labelSlice(self: *const WindowReport) []const u8 {
        return self.label[0..self.label_len];
    }

    pub fn headerNameSlice(self: *const WindowReport) []const u8 {
        return self.header_name[0..self.header_name_len];
    }

    /// Compare two reports. A difference names the field that diverged
    /// instead of returning a bare inequality, so a failure is readable.
    pub fn diff(self: *const WindowReport, other: *const WindowReport) ?[]const u8 {
        if (!std.mem.eql(u8, self.labelSlice(), other.labelSlice())) return "label";
        if (self.observed != other.observed) return "observed revision";
        if (self.clicks != other.clicks) return "header clicks";
        if (self.published_nodes != other.published_nodes) return "published node count";
        if (!std.mem.eql(u8, self.headerNameSlice(), other.headerNameSlice())) return "header name";
        if (self.header_role != other.header_role) return "header role";
        if (self.header_focusable != other.header_focusable) return "header focusable";
        if (self.header_clickable != other.header_clickable) return "header clickable";
        if (self.header_focused != other.header_focused) return "header focused state";
        if (self.focus_is_header != other.focus_is_header) return "committed focus";
        return null;
    }
};

/// The header's own name buffer, stored beside the report so the snapshot's
/// borrowed slice can be copied out while it is still readable.
fn copyHeaderName(report: *WindowReport, name: []const u8) void {
    const taken = @min(name.len, report.header_name.len);
    @memcpy(report.header_name[0..taken], name[0..taken]);
    report.header_name_len = taken;
}

fn windowReport(
    snapshot: ?*const semantics.Snapshot,
    label: []const u8,
    observed: u32,
    clicks: u32,
    focus: ?nogui.WidgetId,
) !WindowReport {
    const live = snapshot orelse return error.MissingSemanticSnapshot;
    var report: WindowReport = .{
        .observed = observed,
        .clicks = clicks,
        .published_nodes = live.count(),
    };
    const taken = @min(label.len, report.label.len);
    @memcpy(report.label[0..taken], label[0..taken]);
    report.label_len = taken;

    const window = live.node(semantics.window_node) orelse return error.MissingSemanticWindow;
    if (window.role != semantics.Role.window) return error.SemanticRootIsNotAWindow;
    // A snapshot without a window root is not a tree an adapter can attach,
    // so the root's presence and role are checked before anything else.

    // The header is the one keyed control the pane publishes. Locating it by
    // role and name is what an accessibility client does; there is no private
    // handle to look it up with.
    for (live.nodes) |*entry| {
        if (entry.role != semantics.Role.button) continue;
        if (!std.mem.eql(u8, entry.name, "header")) continue;
        report.header_role = @backingInt(entry.role);
        copyHeaderName(&report, entry.name);
        report.header_focusable = entry.states.focusable;
        report.header_clickable = entry.actions.has(.click);
        report.header_focused = entry.states.focused;
        report.focus_is_header = if (focus) |current|
            entry.owner != null and entry.owner.?.eql(current)
        else
            false;
        return report;
    }
    return error.MissingSemanticHeader;
}

/// Stage and commit one snapshot from a frame the App just committed. The
/// publisher is separate from the App on purpose: a snapshot belongs to the
/// consumer, and a native adapter reads it after the frame is done. `size` is
/// the surface that window laid out against, in logical units.
fn publishSemantics(
    publisher: *semantics.Publisher,
    app: *App,
    frame: nogui.FrameOutput,
    window_name: []const u8,
    size: nogui.Size,
) !void {
    try publisher.stage(.{
        .tree = frame.tree,
        .focus = frame.focus,
        .generation = app.frame_generation,
        .surface = size,
        .window_name = window_name,
    });
    publisher.commit();
}

/// Which of the two windows an action targets.
pub const WindowSide = enum { left, right };

/// The label a committed tree holds, copied into caller storage so the
/// comparison outlives the frame arena that produced it.
fn labelOf(app: *App) []const u8 {
    const tree = app.tree_ptr orelse return "";
    return firstLabel(tree) orelse "";
}

/// Push one SYNTHETIC mouse click at a window's header button and drain SDL's
/// queue through the host's own routing.
///
/// The point is the button's own laid-out centre, taken from the committed
/// tree; the three events go onto SDL's queue and the App only ever hears the
/// host's translation of them. The coordinates are LOGICAL window points,
/// which is the unit `Window.translate` hands an App: on a scaled display this
/// is NOT where a physical pointer would report, and nothing here claims it is.
fn clickHeaderOn(application: *host.Application, handle: contract.WindowHandle, app: *App) !void {
    const tree = app.tree_ptr orelse return error.NoCommittedTree;
    const id = app.widgetIdForKey(.root, key_header) orelse return error.MissingHeaderIdentity;
    const node = tree.frameNode(id) orelse return error.MissingHeaderNode;
    const rect = nogui.widget.visualBorderRect(tree, node);
    if (rect.w <= 0 or rect.h <= 0) return error.HeaderWasNotLaidOut;
    const point: [2]f32 = .{ rect.x + rect.w / 2, rect.y + rect.h / 2 };
    const native_id = (try application.getWindow(handle)).native.id;
    // A timestamp at or after the window's creation is what the host's
    // stale-event filter requires; SDL_GetTicksNS is the same clock.
    const stamp = sdl3.timer.getNanosecondsSinceInit();
    try sdl3.events.push(.{ .mouse_motion = .{
        .common = .{ .timestamp = stamp },
        .window_id = native_id,
        .state = sdl3.mouse.ButtonFlags.fromSdl(0),
        .x = point[0],
        .y = point[1],
        .x_rel = 0,
        .y_rel = 0,
    } });
    try sdl3.events.push(.{ .mouse_button_down = .{
        .common = .{ .timestamp = stamp },
        .window_id = native_id,
        .button = .left,
        .down = true,
        .clicks = 1,
        .x = point[0],
        .y = point[1],
    } });
    try sdl3.events.push(.{ .mouse_button_up = .{
        .common = .{ .timestamp = stamp },
        .window_id = native_id,
        .button = .left,
        .down = false,
        .clicks = 1,
        .x = point[0],
        .y = point[1],
    } });
    try drainHostQueue(application);
}

/// Drain SDL's queue once and hand each routed translation to the App the host
/// routed it to. This is the host's real input path, not a direct App call.
fn drainHostQueue(application: *host.Application) !void {
    while (application.pollEvent()) |queued| {
        const event = try application.dispatch(&queued) orelse continue;
        switch (event) {
            .window => |routed| {
                const translated = routed.translated orelse continue;
                const app = (try application.getWindow(routed.handle)).app;
                switch (translated) {
                    .input => |value| _ = try app.handle(value),
                    .key_down => |value| _ = try app.handle(value.core),
                    .resize => |value| _ = try app.handle(value.core),
                    .close => return error.HostClosedTheWindow,
                }
            },
            else => {},
        }
    }
}

// ── arm one: the public headless driver ──────────────────────────────────────

/// The whole scenario: build the session, mount two windows, publish frames,
/// mutate through the session, and re-publish.
///
/// The Session, both Apps and both panes are heap-owned. An `App` retains a
/// `*Session` and a `*Pane`; returning those structs by value would leave each
/// App pointing at a dead copy of itself.
pub const Scenario = struct {
    gpa: std.mem.Allocator,
    session: *Session,
    left: *App,
    right: *App,
    left_pane: *Pane,
    right_pane: *Pane,
    owner: nogui.Model(Document),
    /// The label each window published, copied out of its own frame arena so
    /// the caller can compare the two windows after either arena is retired.
    left_label: [16]u8 = undefined,
    right_label: [16]u8 = undefined,
    /// One semantic publisher per window. Each App's tree is published into
    /// its own snapshot, so the two trees never share semantic storage.
    left_semantics: semantics.Publisher,
    right_semantics: semantics.Publisher,

    pub fn init(gpa: std.mem.Allocator) !*Scenario {
        const self = try gpa.create(Scenario);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .session = undefined,
            .left = undefined,
            .right = undefined,
            .left_pane = undefined,
            .right_pane = undefined,
            .owner = undefined,
            .left_semantics = semantics.Publisher.init(gpa),
            .right_semantics = semantics.Publisher.init(gpa),
        };
        errdefer self.right_semantics.deinit();
        errdefer self.left_semantics.deinit();
        self.session = try gpa.create(Session);
        errdefer gpa.destroy(self.session);
        self.session.* = try Session.init(gpa);
        self.left = try gpa.create(App);
        errdefer gpa.destroy(self.left);
        self.left.* = try App.init(gpa, self.session);
        self.right = try gpa.create(App);
        errdefer gpa.destroy(self.right);
        self.right.* = try App.init(gpa, self.session);
        self.left_pane = try gpa.create(Pane);
        errdefer gpa.destroy(self.left_pane);
        self.left_pane.* = .{ .name = "left" };
        self.right_pane = try gpa.create(Pane);
        errdefer gpa.destroy(self.right_pane);
        self.right_pane.* = .{ .name = "right" };
        var initial: Document = .{};
        self.owner = try self.session.create(Document, &initial);
        errdefer self.session.release(Document, &self.owner) catch unreachable;
        try self.left.mountModelRoot(Document, Pane, self.owner, self.left_pane);
        try self.right.mountModelRoot(Document, Pane, self.owner, self.right_pane);
        return self;
    }

    pub fn deinit(self: *Scenario) void {
        const gpa = self.gpa;
        self.session.release(Document, &self.owner) catch unreachable;
        self.right.deinit();
        self.left.deinit();
        self.right_semantics.deinit();
        self.left_semantics.deinit();
        self.session.deinit() catch unreachable;
        gpa.destroy(self.right_pane);
        gpa.destroy(self.left_pane);
        gpa.destroy(self.right);
        gpa.destroy(self.left);
        gpa.destroy(self.session);
        gpa.destroy(self);
    }

    /// The only write path a consumer has for the shared model.
    pub fn bump(self: *Scenario) !void {
        try self.session.update(Document, self.owner, {}, Bump.apply);
    }

    pub fn rename(self: *Scenario, title: []const u8) !void {
        try self.session.update(Document, self.owner, title, Rename.apply);
    }

    /// Read the model through the session, not through a saved pointer.
    pub fn revision(self: *Scenario, comptime T: type, out: *T) !void {
        try self.session.read(Document, self.owner, out, T.read);
    }

    /// Commit and publish ONE window's frame. The other window's tree is not
    /// touched, which is what makes a per-window redraw observable.
    pub fn publishOne(self: *Scenario, side: WindowSide, tick: u32) !void {
        switch (side) {
            .left => {
                const left_frame = try self.left.frame(tick, surface);
                const left_text = firstLabel(left_frame.tree) orelse return error.MissingLeftLabel;
                if (left_text.len + 1 > self.left_label.len) return error.LeftLabelTooLong;
                @memcpy(self.left_label[0..left_text.len], left_text);
                self.left_label[left_text.len] = 0;
                try publishSemantics(&self.left_semantics, self.left, left_frame, "left", surface);
            },
            .right => {
                const right_frame = try self.right.frame(tick, surface);
                const right_text = firstLabel(right_frame.tree) orelse return error.MissingRightLabel;
                if (right_text.len + 1 > self.right_label.len) return error.RightLabelTooLong;
                @memcpy(self.right_label[0..right_text.len], right_text);
                self.right_label[right_text.len] = 0;
                try publishSemantics(&self.right_semantics, self.right, right_frame, "right", surface);
            },
        }
    }

    /// Publish one frame per window. Both windows share the model, so both
    /// repaint; neither window's frame is a side effect of the other's.
    pub fn publish(self: *Scenario, tick: u32) !void {
        try self.publishOne(.left, tick);
        try self.publishOne(.right, tick);
    }

    /// Everything one window's committed frame says, copied out of its own
    /// storage. Both drivers fill the same struct, so the comparison is a
    /// value comparison and not a re-derivation.
    pub fn leftReport(self: *Scenario) !WindowReport {
        return windowReport(
            self.left_semantics.snapshot(),
            self.leftLabel(),
            self.left_pane.observed,
            self.left_pane.clicks,
            self.left.focus_manager.current,
        );
    }

    pub fn rightReport(self: *Scenario) !WindowReport {
        return windowReport(
            self.right_semantics.snapshot(),
            self.rightLabel(),
            self.right_pane.observed,
            self.right_pane.clicks,
            self.right.focus_manager.current,
        );
    }

    pub fn leftLabel(self: *const Scenario) []const u8 {
        return std.mem.sliceTo(self.left_label[0..], 0);
    }

    pub fn rightLabel(self: *const Scenario) []const u8 {
        return std.mem.sliceTo(self.right_label[0..], 0);
    }

    /// Drive the whole scenario through the public headless driver, exactly as
    /// the hosted arms drive it through the host.
    fn run(self: *Scenario, step: *u32) !void {
        // Mounting a model root requests a redraw for that window, and only
        // that one.
        _ = try self.session.takeRedraw(self.left.window);
        _ = try self.session.takeRedraw(self.right.window);

        try self.publishOne(.left, step.*);
        try self.publishOne(.right, step.*);
        // A click on one window's header is local to that window. The pointer
        // goes to the button's real laid-out centre, not a guess.
        try clickHeadless(self, .left);
        try self.bump();
        try self.rename("log");
        step.* += 1;
        try self.publishOne(.left, step.*);
        try self.publishOne(.right, step.*);
    }
};

fn clickHeadless(scenario: *Scenario, which: WindowSide) !void {
    const app = switch (which) {
        .left => scenario.left,
        .right => scenario.right,
    };
    const tree = app.tree_ptr orelse return error.NoCommittedTree;
    const id = app.widgetIdForKey(.root, key_header) orelse
        return error.MissingHeaderIdentity;
    const node = tree.frameNode(id) orelse return error.MissingHeaderNode;
    const rect = nogui.widget.visualBorderRect(tree, node);
    if (rect.w <= 0 or rect.h <= 0) return error.HeaderWasNotLaidOut;
    const point: [2]f32 = .{ rect.x + rect.w / 2, rect.y + rect.h / 2 };
    _ = try app.handle(.{ .mouse_move = .{ .x = point[0], .y = point[1] } });
    _ = try app.handle(.{ .mouse_down = .{
        .button = .left,
        .x = point[0],
        .y = point[1],
    } });
    _ = try app.handle(.{ .mouse_up = .{
        .button = .left,
        .x = point[0],
        .y = point[1],
    } });
}

// ── arm two: the SDL dummy host ──────────────────────────────────────────────

/// The same scenario on a real host with SDL's `dummy` video driver: one
/// `nogui_host.Application`, two REAL windows, one shared model. Input arrives
/// as `sdl3` events pushed onto SDL's own queue and routed by the host, never
/// as a direct `App.handle` call, so the host's window routing and translation
/// are in the path.
///
/// The dummy driver creates real SDL windows with no compositor, no display
/// server and no desktop surface — and, on this arm, no GPU and no present:
/// each frame is a CPU tree. It is the deterministic default, and it is a
/// `dummy` route wherever it is reported.
pub const DummyScenario = struct {
    gpa: std.mem.Allocator,
    session: *Session,
    application: *host.Application,
    left: *App,
    right: *App,
    left_pane: *Pane,
    right_pane: *Pane,
    owner: nogui.Model(Document),
    left_window: contract.WindowHandle,
    right_window: contract.WindowHandle,
    left_managed: *host.ManagedWindow,
    right_managed: *host.ManagedWindow,
    left_semantics: semantics.Publisher,
    right_semantics: semantics.Publisher,
    /// Frame numbers the host drove. The host owns the frame clock here.
    tick: u32 = 0,

    pub fn init(gpa: std.mem.Allocator) !*DummyScenario {
        const self = try gpa.create(DummyScenario);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .session = undefined,
            .application = undefined,
            .left = undefined,
            .right = undefined,
            .left_pane = undefined,
            .right_pane = undefined,
            .owner = undefined,
            .left_window = undefined,
            .right_window = undefined,
            .left_managed = undefined,
            .right_managed = undefined,
            .left_semantics = semantics.Publisher.init(gpa),
            .right_semantics = semantics.Publisher.init(gpa),
        };
        errdefer self.right_semantics.deinit();
        errdefer self.left_semantics.deinit();
        self.session = try gpa.create(Session);
        errdefer gpa.destroy(self.session);
        self.session.* = try Session.init(gpa);
        self.left = try gpa.create(App);
        errdefer gpa.destroy(self.left);
        self.left.* = try App.init(gpa, self.session);
        self.right = try gpa.create(App);
        errdefer gpa.destroy(self.right);
        self.right.* = try App.init(gpa, self.session);
        self.left_pane = try gpa.create(Pane);
        errdefer gpa.destroy(self.left_pane);
        self.left_pane.* = .{ .name = "left" };
        self.right_pane = try gpa.create(Pane);
        errdefer gpa.destroy(self.right_pane);
        self.right_pane.* = .{ .name = "right" };
        var initial: Document = .{};
        self.owner = try self.session.create(Document, &initial);
        errdefer self.session.release(Document, &self.owner) catch unreachable;
        try self.left.mountModelRoot(Document, Pane, self.owner, self.left_pane);
        try self.right.mountModelRoot(Document, Pane, self.owner, self.right_pane);

        // The host owns the windows; the caller keeps both Apps. A borrowed App
        // is retired by the close, not deinitialized, so teardown order below
        // is: close windows, drop the host, then deinitialize the Apps.
        self.application = try gpa.create(host.Application);
        errdefer gpa.destroy(self.application);
        self.application.* = try host.Application.init(gpa, self.session, .{
            .video_driver = "dummy",
            .app_id = app_id,
        });
        // The scenario is heap-owned and outlives the host, so it is a stable
        // hook context for the whole run.
        self.application.setHooks(.{ .context = self, .on_frame = DummyScenario.onFrame });
        self.left_window = try self.application.openWindowWithApp(self.left, .{
            .title = window_title_left,
            .width = @intFromFloat(surface.width),
            .height = @intFromFloat(surface.height),
            .visible = true,
        });
        errdefer _ = self.application.closeWindow(self.left_window) catch {};
        self.right_window = try self.application.openWindowWithApp(self.right, .{
            .title = window_title_right,
            .width = @intFromFloat(surface.width),
            .height = @intFromFloat(surface.height),
            .visible = true,
        });
        self.left_managed = try self.application.getWindow(self.left_window);
        self.right_managed = try self.application.getWindow(self.right_window);
        if (!self.session.hasWindow(self.left_window.session_window)) return error.LeftWindowNotLive;
        if (!self.session.hasWindow(self.right_window.session_window)) return error.RightWindowNotLive;
        return self;
    }

    pub fn deinit(self: *DummyScenario) !void {
        const gpa = self.gpa;
        // The host unregisters its task wake in deinit, so the task service is
        // shut down after it and not before.
        if (!try self.application.closeWindow(self.left_window)) return error.LeftCloseVetoed;
        if (!try self.application.closeWindow(self.right_window)) return error.RightCloseVetoed;
        self.application.deinit();
        gpa.destroy(self.application);
        try self.session.shutdownTasks(task_shutdown_ns);
        self.session.release(Document, &self.owner) catch unreachable;
        self.right.deinit();
        self.left.deinit();
        self.right_semantics.deinit();
        self.left_semantics.deinit();
        self.session.deinit() catch unreachable;
        gpa.destroy(self.right_pane);
        gpa.destroy(self.left_pane);
        gpa.destroy(self.right);
        gpa.destroy(self.left);
        gpa.destroy(self.session);
        gpa.destroy(self);
    }

    pub fn bump(self: *DummyScenario) !void {
        try self.session.update(Document, self.owner, {}, Bump.apply);
    }

    pub fn rename(self: *DummyScenario, title: []const u8) !void {
        try self.session.update(Document, self.owner, title, Rename.apply);
    }

    pub fn revision(self: *DummyScenario, comptime T: type, out: *T) !void {
        try self.session.read(Document, self.owner, out, T.read);
    }

    /// Run the host's own frame loop. `on_frame` publishes each window's
    /// semantics, so a committed frame and its snapshot always agree. The two
    /// managed windows are refreshed here, so their observed geometry is a
    /// reading the platform produced and not an assumption.
    pub fn pump(self: *DummyScenario) !void {
        if (!try self.application.step()) return error.HostStoppedEarly;
        try self.left_managed.refresh();
        try self.right_managed.refresh();
    }

    /// The host's frame callback. It runs each window's App frame and
    /// publishes that window's semantics from the same committed tree, exactly
    /// as a native accessibility adapter would read it.
    fn onFrame(
        raw: *anyopaque,
        _: *host.Application,
        window: *host.ManagedWindow,
        _: nogui.frame_demand.FrameDemand.Work,
    ) anyerror!bool {
        const self: *DummyScenario = @ptrCast(@alignCast(raw));
        self.tick += 1;
        const output = try window.app.frame(self.tick, surface);
        if (window.app == self.left) {
            try publishSemantics(&self.left_semantics, window.app, output, "left", surface);
        } else if (window.app == self.right) {
            try publishSemantics(&self.right_semantics, window.app, output, "right", surface);
        } else {
            return error.ForeignWindowInHost;
        }
        return true;
    }

    /// Push one synthetic mouse click at a window's header button, through
    /// SDL's event queue and the host's own routing.
    pub fn clickHeader(self: *DummyScenario, which: WindowSide) !void {
        const app = switch (which) {
            .left => self.left,
            .right => self.right,
        };
        const handle = switch (which) {
            .left => self.left_window,
            .right => self.right_window,
        };
        try clickHeaderOn(self.application, handle, app);
    }

    pub fn leftReport(self: *DummyScenario) !WindowReport {
        return windowReport(
            self.left_semantics.snapshot(),
            labelOf(self.left),
            self.left_pane.observed,
            self.left_pane.clicks,
            self.left.focus_manager.current,
        );
    }

    pub fn rightReport(self: *DummyScenario) !WindowReport {
        return windowReport(
            self.right_semantics.snapshot(),
            labelOf(self.right),
            self.right_pane.observed,
            self.right_pane.clicks,
            self.right.focus_manager.current,
        );
    }

    /// What this arm observed about one window. `frames_presented` is zero:
    /// the dummy driver owns no swapchain, so there is no present to count.
    fn facts(self: *DummyScenario, side: WindowSide) WindowFacts {
        const managed = switch (side) {
            .left => self.left_managed,
            .right => self.right_managed,
        };
        const state = managed.observed;
        const scale = state.pixelScale() catch nogui.geometry.PixelScale{ .x = 0, .y = 0 };
        return .{
            .window_id = @as(u32, @intCast(managed.native.id)),
            .logical_width = state.size.width,
            .logical_height = state.size.height,
            .device_width = state.pixels.width,
            .device_height = state.pixels.height,
            .scale_x = scale.x,
            .scale_y = scale.y,
            .frames_committed = self.tick,
            .frames_presented = 0,
            .open = true,
            .divergence = if (managed.divergence()) |value| @tagName(value) else null,
        };
    }

    /// The same steps the other arms run, written against this host's own
    /// frame clock: the host commits each window's tree during `pump`.
    fn run(self: *DummyScenario) !void {
        try self.pump();
        try self.clickHeader(.left);
        try self.bump();
        try self.rename("log");
        try self.pump();
    }
};

/// Run the sequence once through the public headless `App` driver. The
/// scenario owns its own Session, so the caller keeps nothing.
pub fn runHeadless(gpa: std.mem.Allocator) !Arm {
    const scenario = try Scenario.init(gpa);
    defer scenario.deinit();

    var step: u32 = 1;
    try scenario.run(&step);
    var seen: ReadRevision = .{};
    try scenario.revision(ReadRevision, &seen);
    return .{
        .mode = "headless",
        .synthetic_input = false,
        .revision = seen.revision,
        .left = try scenario.leftReport(),
        .right = try scenario.rightReport(),
    };
}

/// Run the same sequence through the SDL `dummy` host.
pub fn runDummy(gpa: std.mem.Allocator) !Arm {
    const scenario = try DummyScenario.init(gpa);
    defer scenario.deinit() catch unreachable;

    try scenario.run();
    var seen: ReadRevision = .{};
    try scenario.revision(ReadRevision, &seen);
    return .{
        .mode = "dummy",
        .synthetic_input = true,
        .revision = seen.revision,
        .left = try scenario.leftReport(),
        .right = try scenario.rightReport(),
        .left_facts = scenario.facts(.left),
        .right_facts = scenario.facts(.right),
    };
}

// ── arm three: the presented host ────────────────────────────────────────────

/// The five SPIR-V modules a presented arm records with: the quad pair and the
/// sort compute for the scene renderer, plus the fullscreen vertex stage and
/// the Oklab→sRGB fragment stage the blit samples the Oklab target through.
pub const Shaders = struct {
    vert: []const u32,
    frag: []const u32,
    sort: []const u32,
    fullscreen: []const u32,
    oklab: []const u32,
};

/// One presented window: the App's OWN platform surface and its OWN
/// `v7_frame.NativeFrame` adapter, plus the recording storage both need.
///
/// The adapter and the recording must keep their addresses for their whole
/// life (the adapter's scene scratch borrows its renderer, and the recording's
/// cancellation holds its context), so this value is created in place inside
/// the heap-allocated scenario and is never copied.
const PresentedWindow = struct {
    // SAFETY: the three values below are written by `openWindow` before any
    // reader runs, and their defaults are what let a half-built scenario be
    // released without touching storage nothing opened. `open` is the flag
    // that says whether the window half exists.
    gpa: std.mem.Allocator = undefined,
    io: std.Io = undefined,
    application: *host.Application = undefined,
    handle: contract.WindowHandle = undefined,
    /// SAFETY: like `handle`, written before any reader and valid exactly
    /// while `open` is true.
    managed: *host.ManagedWindow = undefined,
    native_id: sdl3.video.WindowId = 0,
    /// The platform surface `noapi.Surface.initSdl` created from the SDL window
    /// and adopted. It owns the `VkSurfaceKHR` on the way out, so no SDL
    /// wrapper is kept beside it.
    surface: noapi.Surface = undefined,
    adapter: v7_frame.NativeFrame = undefined,
    frame: v7_frame.NativeFrame.Frame = undefined,
    /// What the window ANSWERED: logical units, device pixels, and the device
    /// pixels per logical unit those two produce. Nothing here is authored.
    logical: nogui.geometry.WindowSize = .{ .width = 0, .height = 0 },
    device: noapi.Extent2D = .{ .width = 0, .height = 0 },
    scale: nogui.geometry.PixelScale = .{ .x = 1, .y = 1 },
    /// Acquires this window's swapchain refused as out of date.
    retries: u32 = 0,
    /// The Oklab pixels of this window's last submission. The readback buffer
    /// belongs to the adapter and is reused, so these die at the next render
    /// and at `retire`.
    pixels: []const f32 = &.{},
    /// Pixels of that readback that differ from the clear colour: what a frame
    /// that drew nothing cannot produce.
    ink_pixels: u32 = 0,
    /// The window this run asked for is still open.
    open: bool = false,
    /// SAFETY: set immediately before the resource itself is created, and
    /// cleared immediately after it is released, so `retire` releases exactly
    /// what exists.
    surface_live: bool = false,
    adapter_live: bool = false,

    /// The window's own pixel extent, read from the platform rather than
    /// assumed.
    fn deviceExtent(self: *const PresentedWindow) !noapi.Extent2D {
        const pixels = try self.managed.native.pixelExtent();
        return .{ .width = pixels.width, .height = pixels.height };
    }

    /// Pump the host until this window has SHOWN, bounded, then take the
    /// geometry and the scale it actually answered with. A window that answers
    /// an empty geometry is refused rather than laid out in.
    fn awaitVisible(self: *PresentedWindow) !void {
        var polls: u32 = 0;
        while (polls < readiness_polls) : (polls += 1) {
            if (!try self.application.step()) return error.HostStoppedEarly;
            try self.managed.refresh();
            if (self.managed.observed.visible) {
                const state = self.managed.observed;
                if (state.size.width == 0 or state.size.height == 0 or
                    state.pixels.width == 0 or state.pixels.height == 0)
                {
                    self.reportGeometry(polls);
                    return error.NativeWindowAnsweredAnEmptyGeometry;
                }
                self.logical = .{
                    .width = @floatFromInt(state.size.width),
                    .height = @floatFromInt(state.size.height),
                };
                self.device = .{ .width = state.pixels.width, .height = state.pixels.height };
                self.scale = try state.pixelScale();
                return;
            }
            try std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(poll_delay_ms), .real);
        }
        self.reportGeometry(readiness_polls);
        return error.NativeWindowNeverBecameVisible;
    }

    /// The geometry the window answered, so a refusal is never just a name.
    fn reportGeometry(self: *const PresentedWindow, polls: u32) void {
        const state = self.managed.observed;
        std.debug.print(
            "shared-model: window {d} answered logical {d}x{d}, device {d}x{d}," ++
                " visible={}, host_polls={d}\n",
            .{
                @as(u32, @intCast(self.native_id)),
                state.size.width,
                state.size.height,
                state.pixels.width,
                state.pixels.height,
                state.visible,
                polls,
            },
        );
    }

    /// Build the surface and then the adapter, in the order `retire` reverses.
    /// The two live flags make a failure part way through releasable.
    fn attach(self: *PresentedWindow, gpu: *noapi.Gpu, shaders: Shaders, name: [:0]const u8) !void {
        self.surface = try noapi.Surface.initSdl(
            gpu,
            @ptrCast(self.managed.native.sdl.value),
            @ptrCast(&sdl3.c.SDL_Vulkan_CreateSurface),
            .{ .extent = self.device },
        );
        self.surface_live = true;
        try self.adapter.init(.{
            .allocator = self.gpa,
            .gpu = gpu,
            .fonts = &.{.{ .family = "InterVariable", .bytes = font_bytes }},
            .shaders = .{
                .quad_vert = shaders.vert,
                .quad_frag = shaders.frag,
                .sort_comp = shaders.sort,
                .fullscreen_vert = shaders.fullscreen,
                .blit_oklab = shaders.oklab,
            },
            .name = name,
        });
        self.adapter_live = true;
    }

    /// Every device-side resource this window owns, in the order it owns them:
    /// the adapter, then the surface. The window and SDL are still up when this
    /// returns, because the surface references that window.
    fn retire(self: *PresentedWindow) void {
        if (self.adapter_live) {
            self.adapter.deinit();
            self.adapter_live = false;
        }
        if (self.surface_live) {
            self.surface.deinit();
            self.surface_live = false;
        }
        self.pixels = &.{};
        self.ink_pixels = 0;
    }

    /// Acquire the next image, retarget the Oklab pass to it and open the
    /// recording. An out-of-date swapchain is not a failure: the acquire is
    /// retried inside a bound, with the host pumped between attempts, so a
    /// driver that never settles fails the run instead of spinning.
    fn beginFrame(self: *PresentedWindow) !void {
        var attempts: u32 = 0;
        while (attempts < acquire_polls) : (attempts += 1) {
            self.device = try self.deviceExtent();
            const viewport: v7_frame.NativeFrame.Viewport = .{
                .logical = self.logical,
                .device = self.device,
                .scale = self.scale,
            };
            if (try self.adapter.beginFrame(&self.surface, viewport, &self.frame)) return;
            self.retries += 1;
            if (!try self.application.step()) return error.HostStoppedEarly;
        }
        return error.SwapchainNeverSettled;
    }

    /// The App's committed tree, the Oklab pass, the blit and the present are
    /// ONE event: a frame this arm calls presented is a frame whose pixels
    /// reached the swapchain image, and the readback below comes out of the
    /// Oklab target those same passes wrote.
    fn render(self: *PresentedWindow, output: *const nogui.FrameOutput) !void {
        var painted = try self.adapter.buildScene(.{}, output);
        defer painted.deinit();
        try self.adapter.recordScene(&self.surface, &self.frame, output, &painted);
        // `present` closes the recording itself, so a present that fails must
        // propagate rather than reach a cancellation of a recording that is
        // gone.
        try self.adapter.present(&self.surface, &self.frame);
        self.managed.markPresented();
        self.pixels = try self.adapter.readTarget();
        self.ink_pixels = inkPixels(self.pixels);
    }

    fn cancelFrame(self: *PresentedWindow) void {
        self.adapter.cancelFrame(&self.frame) catch |err| switch (err) {
            error.FrameNotRecording => {},
            else => @panic("shared-model presented recording cancellation failed"),
        };
    }

    /// The extent the last readback describes: the image the passes drew into,
    /// which is what a PPM of that readback means.
    fn pixelExtent(self: *const PresentedWindow) noapi.Extent2D {
        return self.adapter.targetExtent();
    }
};

/// How many pixels of an Oklab readback differ from the colour the scene pass
/// clears the target to. A frame that drew nothing reports zero, which is what
/// makes a still-blank presented window a refusal here.
fn inkPixels(pixels: []const f32) u32 {
    const clear = v7_frame.native.oklab_clear;
    const epsilon: f32 = 1.0 / 512.0;
    var count: u32 = 0;
    var index: usize = 0;
    while (index + 3 < pixels.len) : (index += 4) {
        const differs = @abs(pixels[index] - clear[0]) > epsilon or
            @abs(pixels[index + 1] - clear[1]) > epsilon or
            @abs(pixels[index + 2] - clear[2]) > epsilon;
        if (differs) count += 1;
    }
    return count;
}

/// True when two readbacks are not the same image. Two windows showing one
/// window's pixels twice is the failure this catches.
fn pixelsDiffer(a: []const f32, b: []const f32) bool {
    if (a.len != b.len) return true;
    return !std.mem.eql(u8, std.mem.sliceAsBytes(a), std.mem.sliceAsBytes(b));
}

/// The presented arm: the SAME two Apps and the SAME shared model inside one
/// real `nogui_host.Application`, whose two windows each own a platform
/// surface and a `v7_frame.NativeFrame` adapter over ONE device. Noapi gives
/// every surface its own frame slots on that device, and each window keeps its
/// own text engine, its own Oklab target and its own presentation accounting
/// on top, so the two frame pipelines stay independent.
///
/// This value is heap-allocated once and never copied: the Apps, the panes,
/// the windows, the adapters and their recordings all borrow the address of
/// the value that holds them.
const Presented = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    shaders: Shaders,
    session: Session = undefined,
    left: App = undefined,
    right: App = undefined,
    left_pane: Pane = undefined,
    right_pane: Pane = undefined,
    // SAFETY: the values above are written by `build` before any reader runs;
    // the `live` flags below are the record of which ones exist. The two
    // windows are storage that must not move, so they are declared in place
    // and defaulted rather than left undefined.
    left_window: PresentedWindow = .{},
    right_window: PresentedWindow = .{},
    application: host.Application = undefined,
    /// The left window's facts as they were when it was still open, captured
    /// before its device resources and its ManagedWindow went away.
    left_closed_facts: WindowFacts = .{},
    left_semantics: semantics.Publisher,
    right_semantics: semantics.Publisher,
    /// The caller's own strong ticket, or null once this run has given every
    /// one of them back. The two Apps' retained roots are what keep the model
    /// alive; a null here is the claim that they do.
    owner: ?nogui.Model(Document) = null,
    loader: v7_frame.SystemVulkanLoader = undefined,
    gpu: noapi.Gpu = undefined,
    /// SAFETY: each flag is set immediately after the value it names is
    /// created and cleared immediately after that value is released, so
    /// `deinit` on a half-built run never touches storage nothing built.
    session_live: bool = false,
    left_live: bool = false,
    right_live: bool = false,
    host_live: bool = false,
    loader_live: bool = false,
    gpu_live: bool = false,
    /// Set while this run is closing its OWN window: the close veto protects
    /// the live measurement and must not protect a window its owner retires.
    closing: bool = false,
    /// Every window frame this arm committed, one per `present`.
    tick: u32 = 0,

    fn init(gpa: std.mem.Allocator, io: std.Io, shaders: Shaders) !*Presented {
        const self = try gpa.create(Presented);
        self.* = .{
            .gpa = gpa,
            .io = io,
            .shaders = shaders,
            .left_semantics = semantics.Publisher.init(gpa),
            .right_semantics = semantics.Publisher.init(gpa),
        };
        // One release path for every outcome, including a partial build: it
        // releases only what the live flags say exists, and destroys `self`.
        errdefer self.deinit();
        try self.build();
        return self;
    }

    fn build(self: *Presented) !void {
        self.session = try Session.init(self.gpa);
        self.session_live = true;
        self.left = try App.init(self.gpa, &self.session);
        self.left_live = true;
        self.right = try App.init(self.gpa, &self.session);
        self.right_live = true;
        self.left_pane = .{ .name = "left" };
        self.right_pane = .{ .name = "right" };
        var initial: Document = .{};
        self.owner = try self.session.create(Document, &initial);
        try self.left.mountModelRoot(Document, Pane, self.owner.?, &self.left_pane);
        try self.right.mountModelRoot(Document, Pane, self.owner.?, &self.right_pane);

        self.application = try host.Application.init(self.gpa, &self.session, .{ .app_id = app_id });
        self.host_live = true;
        // The proof window is OURS for the length of the run. A platform close
        // request is vetoed unless this run is the one closing, and losing the
        // last window does not ask the process to quit, so nothing can retire
        // the window this run measures while it measures it.
        self.application.setHooks(.{
            .context = self,
            .on_close_request = vetoClose,
            .on_last_window_closed = keepRunning,
        });
        try self.openWindow(.left);
        try self.openWindow(.right);

        // ONE device for both windows. The loader stays open until every GPU
        // made from its options is gone.
        self.loader = try v7_frame.SystemVulkanLoader.open();
        self.loader_live = true;
        self.gpu = try noapi.Gpu.init(.{
            // Three, not two: the renderer rings its per-frame paint buffers
            // over three slots, one per in-flight frame.
            .frames_in_flight = scene.frames_in_flight,
            .app_name = "nogui_shared_model",
            .validation = false,
            .loader = self.loader.options(),
            .io = self.io,
            .allocator = self.gpa,
        });
        self.gpu_live = true;
        // SDL's own Vulkan subsystem, for the platform surface call and nothing
        // else: on Wayland `SDL_Vulkan_CreateSurface` refuses with "Vulkan is
        // not loaded" unless this has run. The device above is built from the
        // frame module's loader, not from this one.
        try sdl3.vulkan.loadLibrary(null);
        try self.left_window.attach(&self.gpu, self.shaders, "nogui_shared_model_left_blit_oklab");
        try self.right_window.attach(&self.gpu, self.shaders, "nogui_shared_model_right_blit_oklab");

        // Each App measures through the engine that rasterizes ITS window's
        // glyphs, and mounts exactly one endpoint: its own adapter's.
        self.left.measure = self.left_window.adapter.measurer();
        try self.left.attachGpu(self.left_window.adapter.gpuEndpoint());
        self.right.measure = self.right_window.adapter.measurer();
        try self.right.attachGpu(self.right_window.adapter.gpuEndpoint());
    }

    /// Open one window and take the geometry it answers. `open` is set the
    /// moment the handle exists, so a later failure still closes it.
    fn openWindow(self: *Presented, side: WindowSide) !void {
        const window = self.windowForSide(side);
        window.* = .{
            .gpa = self.gpa,
            .io = self.io,
            .application = &self.application,
        };
        window.handle = try self.application.openWindowWithApp(self.appForSide(side), .{
            .title = switch (side) {
                .left => window_title_left,
                .right => window_title_right,
            },
            .width = window_authored.width,
            .height = window_authored.height,
            .resizable = false,
            .visible = true,
            .gpu_surface = true,
        });
        window.open = true;
        window.managed = try self.application.getWindow(window.handle);
        window.native_id = window.managed.native.id;
        try window.awaitVisible();
    }

    /// Every device-side resource, then the windows, then the host, then the
    /// task service, then the model, the Apps, the publishers and the Session.
    /// This is the ONE release path, and it destroys `self`.
    fn deinit(self: *Presented) void {
        const gpa = self.gpa;
        // 1. The Apps let go of the endpoints while the device is still up.
        if (self.left_live) self.left.detachGpu();
        if (self.right_live) self.right.detachGpu();
        // 2. Device-side resources. The windows and SDL are still up, because
        // every surface references the window it presents to.
        if (self.left_window.adapter_live or self.left_window.surface_live) self.left_window.retire();
        if (self.right_window.adapter_live or self.right_window.surface_live) self.right_window.retire();
        if (self.gpu_live) {
            self.gpu.deinit();
            self.gpu_live = false;
        }
        if (self.loader_live) {
            self.loader.close();
            self.loader_live = false;
        }
        // 3. The windows this run still owns, then the host.
        if (self.host_live) {
            self.closeWindow(.left);
            self.closeWindow(.right);
            self.application.deinit();
            self.host_live = false;
        }
        // 4. The task service the host's wake was registered on. A refusal here
        // means worker-owned state is still live, which is a panic and not a
        // release: never free what a worker can still reach.
        if (self.session_live and self.session.tasksStarted()) {
            self.session.shutdownTasks(task_shutdown_ns) catch |err|
                std.debug.panic("shared-model: task shutdown refused {s}", .{@errorName(err)});
        }
        // 5. The caller's ticket if any, then the two Apps (which release their
        // own retained roots), then the publishers, then the Session.
        if (self.owner) |*ticket| {
            self.session.release(Document, ticket) catch unreachable;
            self.owner = null;
        }
        if (self.right_live) {
            self.right.deinit();
            self.right_live = false;
        }
        if (self.left_live) {
            self.left.deinit();
            self.left_live = false;
        }
        self.right_semantics.deinit();
        self.left_semantics.deinit();
        if (self.session_live) {
            self.session.deinit() catch unreachable;
            self.session_live = false;
        }
        gpa.destroy(self);
    }

    /// Close one window this run opened, approving its own close through the
    /// veto that protects a close nobody asked for.
    fn closeWindow(self: *Presented, side: WindowSide) void {
        const window = self.windowForSide(side);
        if (!window.open) return;
        self.closing = true;
        const closed = self.application.closeWindow(window.handle) catch false;
        self.closing = false;
        if (!closed) std.debug.print(
            "shared-model: the host refused to close its own {s} window\n",
            .{@tagName(side)},
        );
        window.open = false;
        // SAFETY: the host has destroyed the ManagedWindow it handed back, so
        // the borrow is dropped here rather than read after the close.
        window.managed = undefined;
    }

    fn vetoClose(context: *anyopaque, _: contract.WindowHandle) bool {
        const self: *Presented = @ptrCast(@alignCast(context));
        return self.closing;
    }

    fn keepRunning(_: *anyopaque, _: *host.Application) host.Application.LastWindowDecision {
        return .keep_running;
    }

    fn appForSide(self: *Presented, side: WindowSide) *App {
        return switch (side) {
            .left => &self.left,
            .right => &self.right,
        };
    }

    fn windowForSide(self: *Presented, side: WindowSide) *PresentedWindow {
        return switch (side) {
            .left => &self.left_window,
            .right => &self.right_window,
        };
    }

    fn publisher(self: *Presented, side: WindowSide) *semantics.Publisher {
        return switch (side) {
            .left => &self.left_semantics,
            .right => &self.right_semantics,
        };
    }

    /// The label the window's committed tree holds, borrowed from that tree.
    fn label(self: *Presented, side: WindowSide) []const u8 {
        return labelOf(self.appForSide(side));
    }

    fn headerId(self: *Presented, side: WindowSide) !nogui.WidgetId {
        return self.appForSide(side).widgetIdForKey(.root, key_header) orelse
            error.MissingHeaderIdentity;
    }

    fn focusIsHeader(self: *Presented, side: WindowSide) bool {
        const app = self.appForSide(side);
        const current = app.focus_manager.current orelse return false;
        const id = app.widgetIdForKey(.root, key_header) orelse return false;
        return current.eql(id);
    }

    /// The only write path a consumer has for the shared model, through
    /// whichever ticket the caller currently holds.
    fn bump(self: *Presented) !void {
        const ticket = self.owner orelse return error.NoCallerTicket;
        try self.session.update(Document, ticket, {}, Bump.apply);
    }

    /// Read the model through the session, not through a saved pointer.
    fn read(self: *Presented, out: *ReadRevision) !void {
        const ticket = self.owner orelse return error.NoCallerTicket;
        try self.session.read(Document, ticket, out, ReadRevision.read);
    }

    /// Give back the caller's own strong ticket. A second ticket is retained
    /// first, so this is the documented "hand the original back" and never the
    /// last reference; the two Apps' retained roots keep the model alive
    /// either way, which is what the frame after this proves.
    fn releaseCallerTicket(self: *Presented) !void {
        var original = self.owner orelse return error.NoCallerTicket;
        self.owner = try self.session.retain(Document, original);
        try self.session.release(Document, &original);
    }

    /// Give back the LAST caller ticket. Nothing outside the two Apps holds the
    /// model after this, so the next frame each window draws is the retention
    /// proof.
    fn releaseLastTicket(self: *Presented) !void {
        var ticket = self.owner orelse return error.NoCallerTicket;
        try self.session.release(Document, &ticket);
        self.owner = null;
    }

    /// Commit one window's frame, publish that frame's semantics, and present
    /// it. The snapshot is staged from the tree the App just committed, so a
    /// semantic claim about this frame cannot describe a different one.
    fn present(self: *Presented, side: WindowSide) !void {
        const window = self.windowForSide(side);
        const app = self.appForSide(side);
        if (!window.open) return error.WindowIsClosed;
        try window.beginFrame();
        errdefer window.cancelFrame();
        self.tick += 1;
        const output = try app.frameWithGpuAtTime(
            self.tick,
            sdl3.timer.getMillisecondsSinceInit(),
            .{ .width = window.logical.width, .height = window.logical.height },
            &window.frame.gpu_frame,
        );
        defer if (output.json) |json| self.gpa.free(json);
        try self.publisher(side).stage(.{
            .tree = output.tree,
            .focus = output.focus,
            .generation = app.frame_generation,
            .surface = .{ .width = window.logical.width, .height = window.logical.height },
            .window_name = switch (side) {
                .left => "left",
                .right => "right",
            },
        });
        self.publisher(side).commit();
        try window.render(&output);
    }

    /// What this window observed, read from the platform and from its own
    /// adapter. Must not be called after the window's device resources are
    /// retired or after its ManagedWindow is gone.
    fn facts(self: *Presented, side: WindowSide) WindowFacts {
        const window = self.windowForSide(side);
        return .{
            .window_id = @as(u32, @intCast(window.native_id)),
            .logical_width = @intFromFloat(window.logical.width),
            .logical_height = @intFromFloat(window.logical.height),
            .device_width = window.device.width,
            .device_height = window.device.height,
            .scale_x = window.scale.x,
            .scale_y = window.scale.y,
            .frames_committed = window.adapter.stats.frames_committed,
            .frames_presented = window.adapter.stats.frames_presented,
            .swapchain_retries = window.retries,
            .open = window.open,
            .divergence = if (window.managed.divergence()) |value| @tagName(value) else null,
        };
    }

    /// Everything both windows' committed frames say, plus the revision the
    /// model answered. Taken while both windows are live and a caller ticket
    /// exists.
    fn report(self: *Presented) !Arm {
        var seen: ReadRevision = .{};
        try self.read(&seen);
        if (!std.mem.eql(u8, self.label(.left), "left r2")) return error.LeftWindowDidNotPaintTheSharedModel;
        if (!std.mem.eql(u8, self.label(.right), "right r2")) return error.RightWindowDidNotPaintTheSharedModel;
        if (self.left_pane.observed != seen.revision or self.right_pane.observed != seen.revision) {
            return error.WindowObservedAStaleRevision;
        }
        return .{
            .mode = "native",
            .synthetic_input = true,
            .revision = seen.revision,
            .left = try windowReport(
                self.left_semantics.snapshot(),
                self.label(.left),
                self.left_pane.observed,
                self.left_pane.clicks,
                self.left.focus_manager.current,
            ),
            .right = try windowReport(
                self.right_semantics.snapshot(),
                self.label(.right),
                self.right_pane.observed,
                self.right_pane.clicks,
                self.right.focus_manager.current,
            ),
            .left_facts = self.facts(.left),
            .right_facts = self.facts(.right),
        };
    }

    /// Run the SAME script the other two arms run, then the presentations and
    /// the retirement this arm adds, and return what the shared script's end
    /// observed plus the evidence the extra steps produced.
    fn runScript(self: *Presented) !void {
        // ── Both windows mount the SAME model root and present their own
        // frame from it. ──
        try self.present(.left);
        try self.present(.right);
        // Both windows really drew: each readback holds ink this frame put
        // there, and the two are NOT the same image, so neither window's
        // pixels are a copy of the other's.
        if (self.left_window.ink_pixels == 0) return error.LeftWindowDrewNothing;
        if (self.right_window.ink_pixels == 0) return error.RightWindowDrewNothing;
        if (!pixelsDiffer(self.left_window.pixels, self.right_window.pixels)) {
            return error.BothWindowsPresentedTheSameImage;
        }
        if (self.left_window.adapter.stats.frames_presented == 0) return error.LeftWindowPresentedNothing;
        if (self.right_window.adapter.stats.frames_presented == 0) return error.RightWindowPresentedNothing;

        // The same keyed header in two windows is two unrelated widget ids, and
        // neither window's tree resolves the other's id. Those two ids are
        // captured here and re-checked after the shared model moves and after
        // one window is closed.
        const left_header = try self.headerId(.left);
        const right_header = try self.headerId(.right);
        if (left_header.eql(right_header)) return error.WindowsShareOneWidgetIdentity;
        if (self.left.tree_ptr.?.frameNode(right_header) != null) {
            return error.LeftTreeHoldsTheRightWindowsWidget;
        }
        if (self.right.tree_ptr.?.frameNode(left_header) != null) {
            return error.RightTreeHoldsTheLeftWindowsWidget;
        }

        // A queued SDL click does not activate its native window. Settle the
        // actual focus first so a delayed focus-lost event cannot clear the
        // logical header focus after the synthetic click.
        try self.left_window.managed.requestFocus();
        var focus_polls: u32 = 0;
        while (focus_polls < readiness_polls) : (focus_polls += 1) {
            if (!try self.application.step()) return error.HostStoppedEarly;
            try self.left_window.managed.refresh();
            if (self.left_window.managed.observed.focused) break;
            try std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(poll_delay_ms), .real);
        }
        if (!self.left_window.managed.observed.focused) return error.NativeWindowNeverFocused;

        // ── ONE synthetic click on the LEFT window's header, through SDL's
        // queue and the host's own routing. It lands in exactly one window. ──
        try clickHeaderOn(&self.application, self.left_window.handle, &self.left);
        if (self.left_pane.clicks != 1) return error.LeftHeaderDidNotActivate;
        if (self.right_pane.clicks != 0) return error.ClickCrossedWindows;
        if (!self.focusIsHeader(.left)) return error.LeftWindowDidNotFocusItsHeader;
        if (self.focusIsHeader(.right)) return error.RightWindowTookTheLeftWindowsFocus;

        // ── ONE model write. Both windows are invalidated and both present the
        // new revision; the revision moved exactly once. ──
        var before: ReadRevision = .{};
        try self.read(&before);
        try self.bump();
        // The document's other field goes through the same writer and must not
        // move the revision both windows paint.
        try self.session.update(Document, self.owner.?, "log", Rename.apply);
        var after: ReadRevision = .{};
        try self.read(&after);
        if (after.revision != before.revision + 1) return error.SharedModelDidNotAdvanceOnce;
        try self.present(.left);
        try self.present(.right);

        // The stable ids survive the update: the same key still resolves to the
        // same id in the same window, and never to the other window's.
        if (!(try self.headerId(.left)).eql(left_header)) return error.LeftHeaderIdentityMoved;
        if (!(try self.headerId(.right)).eql(right_header)) return error.RightHeaderIdentityMoved;
    }

    /// The presentations and the retirements this arm adds after the shared
    /// script: the caller's tickets go one at a time while both windows keep
    /// drawing, and then ONE window is closed while the other keeps presenting.
    /// Returns the evidence of what each step observed.
    fn runExtra(
        self: *Presented,
        evidence: NativeEvidence,
        ppm_left: ?[]const u8,
        ppm_right: ?[]const u8,
    ) !NativeEvidence {
        var observed = evidence;
        // ── The caller's ORIGINAL ticket goes. Both windows still draw the
        // model, which now lives on the Apps' retained roots and the second
        // ticket this retained. ──
        try self.releaseCallerTicket();
        try self.present(.left);
        try self.present(.right);
        if (!std.mem.eql(u8, self.label(.left), "left r2")) return error.ModelDiedWithTheCallersTicket;
        if (!std.mem.eql(u8, self.label(.right), "right r2")) return error.ModelDiedWithTheCallersTicket;
        observed.caller_ticket_released = true;

        // ── The ticket kept above writes, and BOTH windows take the update. ──
        try self.bump();
        try self.present(.left);
        try self.present(.right);
        if (!std.mem.eql(u8, self.label(.left), "left r3")) return error.LeftWindowMissedTheSecondUpdate;
        if (!std.mem.eql(u8, self.label(.right), "right r3")) return error.RightWindowMissedTheSecondUpdate;
        observed.surviving_ticket_wrote = true;
        observed.last_presented_revision = 3;

        // ── Even that ticket goes. Nothing outside the two Apps holds the
        // model now, and both windows still present it. ──
        const left_before = self.left_window.adapter.stats.frames_presented;
        const right_before = self.right_window.adapter.stats.frames_presented;
        try self.releaseLastTicket();
        try self.present(.left);
        try self.present(.right);
        if (!std.mem.eql(u8, self.label(.left), "left r3")) return error.ModelDiedWithTheLastCallerTicket;
        if (!std.mem.eql(u8, self.label(.right), "right r3")) return error.ModelDiedWithTheLastCallerTicket;
        if (self.left_window.adapter.stats.frames_presented <= left_before) {
            return error.LeftWindowStoppedPresenting;
        }
        if (self.right_window.adapter.stats.frames_presented <= right_before) {
            return error.RightWindowStoppedPresenting;
        }
        observed.all_caller_tickets_released = true;

        // ── The optional PPMs come out of the readbacks above, while both
        // windows' adapters are still live. ──
        if (ppm_left) |path| try v7_frame.writePpm(
            self.gpa,
            self.io,
            path,
            self.left_window.pixels,
            self.left_window.pixelExtent(),
        );
        if (ppm_right) |path| try v7_frame.writePpm(
            self.gpa,
            self.io,
            path,
            self.right_window.pixels,
            self.right_window.pixelExtent(),
        );

        // ── ONE window is retired and closed. Its device resources go first,
        // then the window, and the surviving window's surface, adapter, device
        // and model are untouched by both. ──
        observed.left_frames_presented = self.left_window.adapter.stats.frames_presented;
        observed.left_ink_pixels = self.left_window.ink_pixels;
        observed.right_frames_presented = self.right_window.adapter.stats.frames_presented;
        observed.right_ink_pixels = self.right_window.ink_pixels;
        observed.windows_distinct_pixels = true;
        const left_facts_open = self.facts(.left);
        // The App lets go of the endpoint while the device is still up; only
        // then may the adapter and the surface go, and only then the window.
        self.left.detachGpu();
        self.left_window.retire();
        self.closeWindow(.left);
        if (self.session.hasWindow(self.left_window.handle.session_window)) {
            return error.LeftWindowStillRegistered;
        }
        if (!self.session.hasWindow(self.right_window.handle.session_window)) {
            return error.RightWindowWasRetiredToo;
        }
        observed.closed_one_window = true;
        self.left_closed_facts = left_facts_open;
        self.left_closed_facts.open = false;

        // ── The surviving window presents again, still paints the shared
        // model, and still resolves its own header identity. ──
        const surviving_before = self.right_window.adapter.stats.frames_presented;
        const right_header = try self.headerId(.right);
        try self.present(.right);
        if (self.right_window.adapter.stats.frames_presented <= surviving_before) {
            return error.SurvivingWindowStoppedPresenting;
        }
        if (!std.mem.eql(u8, self.label(.right), "right r3")) return error.SurvivingWindowLostTheSharedModel;
        if (self.right_window.ink_pixels == 0) return error.SurvivingWindowDrewNothing;
        if (!(try self.headerId(.right)).eql(right_header)) return error.SurvivingWindowIdentityMoved;
        observed.surviving_window_presented = true;
        return observed;
    }
};

// ── the record ───────────────────────────────────────────────────────────────

/// What one window's arm observed, and nothing this file authored. The dummy
/// arm reports `frames_presented = 0` because it has no swapchain, and the
/// windowless arm reports a null window id and a zero extent because it has no
/// window at all: a zero or a null here is the ABSENCE of a platform reading,
/// never a measurement this file made up.
pub const WindowFacts = struct {
    /// The platform's own window id.
    window_id: ?u32 = null,
    /// The logical size the window answered.
    logical_width: u32 = 0,
    logical_height: u32 = 0,
    /// The device pixel extent the window answered.
    device_width: u32 = 0,
    device_height: u32 = 0,
    /// Device pixels per logical unit, from those two readings. Zero when the
    /// platform could not be asked.
    scale_x: f32 = 0,
    scale_y: f32 = 0,
    /// Frames the route committed for this window.
    frames_committed: u32 = 0,
    /// Frames this window's surface presented. Only a presented arm can report
    /// a non-zero value here, and it reports the frame module's own count.
    frames_presented: u32 = 0,
    /// Acquires this window's swapchain refused as out of date.
    swapchain_retries: u32 = 0,
    /// The window was still open when the record was taken.
    open: bool = true,
    /// The first requested/observed disagreement, or null when there is none.
    divergence: ?[]const u8 = null,
};

/// What the presented arm proved beyond the shared script. Every field is set
/// only after the observation behind it held, so a false here is a step this
/// run did not reach — never one it assumed.
pub const NativeEvidence = struct {
    /// The caller's original ticket was released and both windows still drew.
    caller_ticket_released: bool = false,
    /// A write through the surviving ticket reached BOTH windows.
    surviving_ticket_wrote: bool = false,
    /// The last caller ticket was released and both windows still drew.
    all_caller_tickets_released: bool = false,
    /// The revision the last presented frame painted.
    last_presented_revision: u32 = 0,
    /// One window was closed by this run and retired from the session.
    closed_one_window: bool = false,
    /// The surviving window presented again and still painted the model.
    surviving_window_presented: bool = false,
    /// Pixels of each window's readback that differ from the clear colour.
    left_ink_pixels: u32 = 0,
    right_ink_pixels: u32 = 0,
    /// The two windows' readbacks were different images.
    windows_distinct_pixels: bool = false,
    left_frames_presented: u32 = 0,
    right_frames_presented: u32 = 0,
};

/// One arm's whole result: what each window's committed frame said, the
/// revision the model answered, and what the platform observed. `mode` names
/// the arm honestly, and only the platform description is ever held apart.
pub const Arm = struct {
    mode: []const u8,
    synthetic_input: bool,
    revision: u32,
    left: WindowReport,
    right: WindowReport,
    left_facts: WindowFacts = .{},
    right_facts: WindowFacts = .{},
    /// Set only by the presented arm.
    evidence: ?NativeEvidence = null,
};

/// The two window reports must agree field by field, and so must the revision
/// the model answered. Only the platform description is held apart.
fn expectAgreement(reference: *const Arm, other: *const Arm) !void {
    if (reference.left.diff(&other.left)) |field| {
        std.debug.print(
            "shared-model: left {s} diverged: {s} != {s}\n",
            .{ field, reference.left.labelSlice(), other.left.labelSlice() },
        );
        return error.LeftWindowDiverged;
    }
    if (reference.right.diff(&other.right)) |field| {
        std.debug.print(
            "shared-model: right {s} diverged: {s} != {s}\n",
            .{ field, reference.right.labelSlice(), other.right.labelSlice() },
        );
        return error.RightWindowDiverged;
    }
    if (reference.revision != other.revision) {
        std.debug.print(
            "shared-model: revision diverged: {d} != {d}\n",
            .{ reference.revision, other.revision },
        );
        return error.RevisionDiverged;
    }
}

fn appendJsonString(out: *std.ArrayList(u8), gpa: std.mem.Allocator, bytes: []const u8) !void {
    try out.append(gpa, '"');
    for (bytes) |byte| switch (byte) {
        '"' => try out.appendSlice(gpa, "\\\""),
        '\\' => try out.appendSlice(gpa, "\\\\"),
        '\n' => try out.appendSlice(gpa, "\\n"),
        '\r' => try out.appendSlice(gpa, "\\r"),
        '\t' => try out.appendSlice(gpa, "\\t"),
        0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => try out.print(gpa, "\\u{x:0>4}", .{byte}),
        // A UTF-8 continuation byte is part of the value, not a control
        // character: the record is UTF-8 and those bytes pass through.
        else => try out.append(gpa, byte),
    };
    try out.append(gpa, '"');
}

fn appendName(gpa: std.mem.Allocator, out: *std.ArrayList(u8), name: []const u8) !void {
    if (out.items.len != 0) try out.append(gpa, ',');
    try appendJsonString(out, gpa, name);
    try out.append(gpa, ':');
}

fn appendValue(
    gpa: std.mem.Allocator,
    out: *std.ArrayList(u8),
    name: []const u8,
    comptime fmt: []const u8,
    value: anytype,
) !void {
    try appendName(gpa, out, name);
    const text = try std.fmt.allocPrint(gpa, fmt, .{value});
    defer gpa.free(text);
    try out.appendSlice(gpa, text);
}

fn appendBool(gpa: std.mem.Allocator, out: *std.ArrayList(u8), name: []const u8, value: bool) !void {
    try appendName(gpa, out, name);
    try out.appendSlice(gpa, if (value) "true" else "false");
}

fn appendText(gpa: std.mem.Allocator, out: *std.ArrayList(u8), name: []const u8, value: []const u8) !void {
    try appendName(gpa, out, name);
    try appendJsonString(out, gpa, value);
}

/// One window's report as its own JSON object. The object is built in its own
/// buffer, so the comma rule of the enclosing object cannot reach inside it and
/// a first inner entry never gets a leading comma.
fn appendReport(
    gpa: std.mem.Allocator,
    out: *std.ArrayList(u8),
    name: []const u8,
    report: *const WindowReport,
) !void {
    var inner: std.ArrayList(u8) = .empty;
    defer inner.deinit(gpa);
    try appendText(gpa, &inner, "label", report.labelSlice());
    try appendValue(gpa, &inner, "observed", "{d}", report.observed);
    try appendValue(gpa, &inner, "clicks", "{d}", report.clicks);
    try appendValue(gpa, &inner, "published_nodes", "{d}", report.published_nodes);
    try appendText(
        gpa,
        &inner,
        "header_role",
        @tagName(@as(semantics.Role, @fromBackingInt(@intCast(report.header_role)))),
    );
    try appendText(gpa, &inner, "header_name", report.headerNameSlice());
    try appendBool(gpa, &inner, "header_focusable", report.header_focusable);
    try appendBool(gpa, &inner, "header_clickable", report.header_clickable);
    try appendBool(gpa, &inner, "header_focused", report.header_focused);
    try appendBool(gpa, &inner, "focus_is_header", report.focus_is_header);
    try appendName(gpa, out, name);
    try out.append(gpa, '{');
    try out.appendSlice(gpa, inner.items);
    try out.append(gpa, '}');
}

fn appendFacts(
    gpa: std.mem.Allocator,
    out: *std.ArrayList(u8),
    name: []const u8,
    facts: *const WindowFacts,
) !void {
    var inner: std.ArrayList(u8) = .empty;
    defer inner.deinit(gpa);
    try appendValue(gpa, &inner, "window_id", "{?d}", facts.window_id);
    try appendValue(gpa, &inner, "logical_width", "{d}", facts.logical_width);
    try appendValue(gpa, &inner, "logical_height", "{d}", facts.logical_height);
    try appendValue(gpa, &inner, "device_width", "{d}", facts.device_width);
    try appendValue(gpa, &inner, "device_height", "{d}", facts.device_height);
    try appendValue(gpa, &inner, "scale_x", "{d:.3}", facts.scale_x);
    try appendValue(gpa, &inner, "scale_y", "{d:.3}", facts.scale_y);
    try appendValue(gpa, &inner, "frames_committed", "{d}", facts.frames_committed);
    try appendValue(gpa, &inner, "frames_presented", "{d}", facts.frames_presented);
    try appendValue(gpa, &inner, "swapchain_retries", "{d}", facts.swapchain_retries);
    try appendBool(gpa, &inner, "open", facts.open);
    try appendName(gpa, &inner, "divergence");
    if (facts.divergence) |divergence| {
        try appendJsonString(&inner, gpa, divergence);
    } else {
        try inner.appendSlice(gpa, "null");
    }
    try appendName(gpa, out, name);
    try out.append(gpa, '{');
    try out.appendSlice(gpa, inner.items);
    try out.append(gpa, '}');
}

/// One `SHARED-MODEL` line: a single strict JSON object, written only after
/// every expectation above held.
fn emitArm(gpa: std.mem.Allocator, io: std.Io, arm: *const Arm) !void {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    try appendText(gpa, &body, "record", "shared-model");
    try appendText(gpa, &body, "mode", arm.mode);
    try appendBool(gpa, &body, "synthetic_input", arm.synthetic_input);
    try appendValue(gpa, &body, "revision", "{d}", arm.revision);
    try appendReport(gpa, &body, "left", &arm.left);
    try appendReport(gpa, &body, "right", &arm.right);
    try appendFacts(gpa, &body, "left_window", &arm.left_facts);
    try appendFacts(gpa, &body, "right_window", &arm.right_facts);
    if (arm.evidence) |evidence| {
        var inner: std.ArrayList(u8) = .empty;
        defer inner.deinit(gpa);
        try appendBool(gpa, &inner, "caller_ticket_released", evidence.caller_ticket_released);
        try appendBool(gpa, &inner, "surviving_ticket_wrote", evidence.surviving_ticket_wrote);
        try appendBool(gpa, &inner, "all_caller_tickets_released", evidence.all_caller_tickets_released);
        try appendValue(gpa, &inner, "last_presented_revision", "{d}", evidence.last_presented_revision);
        try appendBool(gpa, &inner, "closed_one_window", evidence.closed_one_window);
        try appendBool(gpa, &inner, "surviving_window_presented", evidence.surviving_window_presented);
        try appendValue(gpa, &inner, "left_ink_pixels", "{d}", evidence.left_ink_pixels);
        try appendValue(gpa, &inner, "right_ink_pixels", "{d}", evidence.right_ink_pixels);
        try appendBool(gpa, &inner, "windows_distinct_pixels", evidence.windows_distinct_pixels);
        try appendValue(gpa, &inner, "left_frames_presented", "{d}", evidence.left_frames_presented);
        try appendValue(gpa, &inner, "right_frames_presented", "{d}", evidence.right_frames_presented);
        try appendName(gpa, &body, "presented_evidence");
        try body.append(gpa, '{');
        try body.appendSlice(gpa, inner.items);
        try body.append(gpa, '}');
    }
    try body.append(gpa, '}');

    const line = try std.fmt.allocPrint(gpa, "SHARED-MODEL {{{s}\n", .{body.items});
    defer gpa.free(line);
    try std.Io.File.stdout().writeStreamingAll(io, line);
}

/// Run the presented arm: the shared script, then the presentations and the
/// retirements only a presented arm can make, then the readbacks. Every step
/// refuses rather than reporting if what it observed is not what this file
/// claims.
pub fn runNative(
    gpa: std.mem.Allocator,
    io: std.Io,
    shaders: Shaders,
    ppm_left: ?[]const u8,
    ppm_right: ?[]const u8,
) !Arm {
    const presented = try Presented.init(gpa, io, shaders);
    defer presented.deinit();

    try presented.runScript();
    var arm = try presented.report();
    // The script's end is what the other arms are compared against. The
    // evidence below comes from presentations this arm adds after it.
    const evidence = try presented.runExtra(NativeEvidence{}, ppm_left, ppm_right);
    if (!evidence.caller_ticket_released or !evidence.surviving_ticket_wrote or
        !evidence.all_caller_tickets_released or !evidence.closed_one_window or
        !evidence.surviving_window_presented or !evidence.windows_distinct_pixels)
    {
        return error.PresentedEvidenceIncomplete;
    }
    // The facts are taken at the very end: they describe the whole run,
    // including the frames presented after the shared script's end. The left
    // window's facts were captured before its close, so its record says the
    // window this run presented and then retired.
    arm.left_facts = presented.left_closed_facts;
    arm.right_facts = presented.facts(.right);
    arm.evidence = evidence;

    // Let the platform process the last presents, bounded, so a person
    // watching the windows sees the frames this record describes.
    var polls: u32 = 0;
    while (polls < hold_polls) : (polls += 1) {
        if (!try presented.application.step()) return error.HostStoppedEarly;
    }
    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(poll_delay_ms), .real);
    return arm;
}

// ── the command line ─────────────────────────────────────────────────────────

/// One loaded SPIR-V module: the bytes, and the u32 view the GPU wants.
const ShaderFile = struct {
    bytes: []u8,
    words: []const u32,

    fn load(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !ShaderFile {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
        errdefer gpa.free(bytes);
        if (bytes.len == 0 or bytes.len % @sizeOf(u32) != 0) return error.InvalidShaderBytes;
        return .{
            .bytes = bytes,
            .words = @alignCast(std.mem.bytesAsSlice(u32, bytes)),
        };
    }

    fn deinit(self: *ShaderFile, gpa: std.mem.Allocator) void {
        gpa.free(self.bytes);
        self.* = undefined;
    }
};

const RunOptions = struct {
    native: bool = false,
    vert: ?[]const u8 = null,
    frag: ?[]const u8 = null,
    sort: ?[]const u8 = null,
    fullscreen: ?[]const u8 = null,
    oklab: ?[]const u8 = null,
    ppm: ?[]const u8 = null,
    ppm_right: ?[]const u8 = null,

    /// The modules are named by the build step; each falls back to the in-tree
    /// path the presented parity examples already require.
    fn vertPath(self: RunOptions) []const u8 {
        return self.vert orelse "shaders/quad_vert.spv";
    }

    fn fragPath(self: RunOptions) []const u8 {
        return self.frag orelse "shaders/quad_frag.spv";
    }

    fn sortPath(self: RunOptions) []const u8 {
        return self.sort orelse "shaders/sort_comp.spv";
    }

    fn fullscreenPath(self: RunOptions) []const u8 {
        return self.fullscreen orelse "shaders/fullscreen_vert.spv";
    }

    fn oklabPath(self: RunOptions) []const u8 {
        return self.oklab orelse "shaders/blit_oklab.spv";
    }

    fn wantsPpm(self: RunOptions) bool {
        return self.ppm != null or self.ppm_right != null;
    }
};

/// The five modules the presented arm needs. `init` loads in the reverse of
/// `deinit`, and a failure part way through still releases what loaded.
const Rig = struct {
    gpa: std.mem.Allocator,
    vert: ShaderFile = undefined,
    frag: ShaderFile = undefined,
    sort: ShaderFile = undefined,
    fullscreen: ShaderFile = undefined,
    oklab: ShaderFile = undefined,

    fn init(gpa: std.mem.Allocator, io: std.Io, options: RunOptions) !Rig {
        var self: Rig = .{ .gpa = gpa };
        self.vert = try ShaderFile.load(gpa, io, options.vertPath());
        errdefer self.vert.deinit(gpa);
        self.frag = try ShaderFile.load(gpa, io, options.fragPath());
        errdefer self.frag.deinit(gpa);
        self.sort = try ShaderFile.load(gpa, io, options.sortPath());
        errdefer self.sort.deinit(gpa);
        self.oklab = try ShaderFile.load(gpa, io, options.oklabPath());
        errdefer self.oklab.deinit(gpa);
        self.fullscreen = try ShaderFile.load(gpa, io, options.fullscreenPath());
        return self;
    }

    fn shaders(self: *const Rig) Shaders {
        return .{
            .vert = self.vert.words,
            .frag = self.frag.words,
            .sort = self.sort.words,
            .fullscreen = self.fullscreen.words,
            .oklab = self.oklab.words,
        };
    }

    fn deinit(self: *Rig) void {
        self.fullscreen.deinit(self.gpa);
        self.oklab.deinit(self.gpa);
        self.sort.deinit(self.gpa);
        self.frag.deinit(self.gpa);
        self.vert.deinit(self.gpa);
        self.* = undefined;
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args.deinit();
    _ = args.next() orelse return error.MissingExecutableName;
    var options: RunOptions = .{};
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--native")) {
            options.native = true;
        } else if (std.mem.eql(u8, arg, "--ppm")) {
            if (options.ppm != null) return error.RepeatedArgument;
            options.ppm = args.next() orelse return error.MissingArgument;
        } else if (std.mem.eql(u8, arg, "--ppm-right")) {
            if (options.ppm_right != null) return error.RepeatedArgument;
            options.ppm_right = args.next() orelse return error.MissingArgument;
        } else if (std.mem.eql(u8, arg, "--quad-vert")) {
            if (options.vert != null) return error.RepeatedArgument;
            options.vert = args.next() orelse return error.MissingArgument;
        } else if (std.mem.eql(u8, arg, "--quad-frag")) {
            if (options.frag != null) return error.RepeatedArgument;
            options.frag = args.next() orelse return error.MissingArgument;
        } else if (std.mem.eql(u8, arg, "--sort-comp")) {
            if (options.sort != null) return error.RepeatedArgument;
            options.sort = args.next() orelse return error.MissingArgument;
        } else if (std.mem.eql(u8, arg, "--fullscreen-vert")) {
            if (options.fullscreen != null) return error.RepeatedArgument;
            options.fullscreen = args.next() orelse return error.MissingArgument;
        } else if (std.mem.eql(u8, arg, "--blit-oklab")) {
            if (options.oklab != null) return error.RepeatedArgument;
            options.oklab = args.next() orelse return error.MissingArgument;
        } else {
            return error.UnknownArgument;
        }
    }

    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    if (!options.native) {
        // Neither windowless arm has a surface to present, so a PPM would
        // describe pixels that were never drawn into a swapchain image.
        if (options.wantsPpm()) return error.PpmNeedsThePresentedArm;
        const headless = try runHeadless(gpa);
        try emitArm(gpa, io, &headless);
        const dummy = try runDummy(gpa);
        try expectAgreement(&headless, &dummy);
        try emitArm(gpa, io, &dummy);
        std.debug.print("shared-model: the dummy host agrees with the headless driver\n", .{});
        return;
    }

    var rig = try Rig.init(gpa, io, options);
    defer rig.deinit();
    // The reference first: a delta this arm did not author.
    const headless = try runHeadless(gpa);
    try emitArm(gpa, io, &headless);
    const native = try runNative(gpa, io, rig.shaders(), options.ppm, options.ppm_right);
    try expectAgreement(&headless, &native);
    try emitArm(gpa, io, &native);
    std.debug.print(
        "shared-model: presented left {d}x{d}@{d:.2}x, right {d}x{d}@{d:.2}x\n",
        .{
            native.left_facts.device_width,
            native.left_facts.device_height,
            native.left_facts.scale_x,
            native.right_facts.device_width,
            native.right_facts.device_height,
            native.right_facts.scale_x,
        },
    );
}

test "api-w25 one model drives two windows with independent arenas and widget ids" {
    var gpa_state: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    defer std.testing.expect(gpa_state.deinit() == 0) catch {};
    const gpa = gpa_state.allocator();

    const scenario = try Scenario.init(gpa);
    defer scenario.deinit();

    // Mounting a model root requests a redraw for that window only.
    try std.testing.expect(try scenario.session.takeRedraw(scenario.left.window));
    try std.testing.expect(try scenario.session.takeRedraw(scenario.right.window));
    try std.testing.expect(!try scenario.session.takeRedraw(scenario.left.window));
    try std.testing.expect(!try scenario.session.takeRedraw(scenario.right.window));

    // Each window sees the initial model through its own frame pipeline.
    try scenario.publish(1);
    try std.testing.expectEqualStrings("left r1", scenario.leftLabel());
    try std.testing.expectEqualStrings("right r1", scenario.rightLabel());
    try std.testing.expectEqual(@as(u32, 1), scenario.left_pane.observed);
    try std.testing.expectEqual(@as(u32, 1), scenario.right_pane.observed);

    // The frame arenas are per-App, not per-Session: the two windows can never
    // hand each other a frame-local allocation.
    try std.testing.expect(&scenario.left.arenas != &scenario.right.arenas);
    try std.testing.expect(scenario.left.tree_ptr.? != scenario.right.tree_ptr.?);
    const left_arena = scenario.left.arenas[scenario.left.current].allocator();
    const right_arena = scenario.right.arenas[scenario.right.current].allocator();
    const left_slice = try left_arena.alloc(u8, 8);
    const right_slice = try right_arena.alloc(u8, 8);
    @memset(left_slice, 0xA1);
    @memset(right_slice, 0xB2);
    // Distinct backing storage: a pointer into one window's frame arena is
    // never a pointer into the other's, and the bytes are independent.
    try std.testing.expect(@intFromPtr(left_slice.ptr) != @intFromPtr(right_slice.ptr));
    try std.testing.expectEqual(@as(u8, 0xA1), left_slice[0]);
    try std.testing.expectEqual(@as(u8, 0xB2), right_slice[0]);

    // The identity registries are per-App too, so the same ComponentKey in two
    // windows is two unrelated stable ids. A pane's own click never fires the
    // other window's handler.
    const left_header = scenario.left.widgetIdForKey(.root, key_header) orelse
        return error.MissingLeftHeader;
    const right_header = scenario.right.widgetIdForKey(.root, key_header) orelse
        return error.MissingRightHeader;
    try std.testing.expect(left_header.owner != right_header.owner);
    try std.testing.expect(!left_header.eql(right_header));
    // An id from one window is not present in the other window's tree.
    try std.testing.expect(scenario.left.tree_ptr.?.frameNode(right_header) == null);
    try std.testing.expect(scenario.right.tree_ptr.?.frameNode(left_header) == null);

    // A click routed to the left window's header touches only the left pane.
    // The pointer goes to the button's real laid-out centre, not a guess.
    try clickHeadless(scenario, .left);
    try std.testing.expectEqual(@as(u32, 1), scenario.left_pane.clicks);
    try std.testing.expectEqual(@as(u32, 0), scenario.right_pane.clicks);
    try std.testing.expectEqual(@as(u32, 1), scenario.left_pane.observed);
    try std.testing.expectEqual(@as(u32, 1), scenario.right_pane.observed);
    // The click is a local view mutation: the shared model did not change.
    var after_click: ReadRevision = .{};
    try scenario.revision(ReadRevision, &after_click);
    try std.testing.expectEqual(@as(u32, 1), after_click.revision);

    // One session write invalidates BOTH windows; each repaints to the new value.
    try scenario.bump();
    try scenario.rename("log");
    try std.testing.expect(try scenario.session.takeRedraw(scenario.left.window));
    try std.testing.expect(try scenario.session.takeRedraw(scenario.right.window));
    try std.testing.expect(!try scenario.session.takeRedraw(scenario.left.window));
    try std.testing.expect(!try scenario.session.takeRedraw(scenario.right.window));

    try scenario.publish(3);
    try std.testing.expectEqualStrings("left r2", scenario.leftLabel());
    try std.testing.expectEqualStrings("right r2", scenario.rightLabel());
    try std.testing.expectEqual(@as(u32, 2), scenario.left_pane.observed);
    try std.testing.expectEqual(@as(u32, 2), scenario.right_pane.observed);

    // The stable ids survive a frame: the same key resolves to the same id.
    const left_again = scenario.left.widgetIdForKey(.root, key_header) orelse
        return error.MissingLeftHeader;
    const right_again = scenario.right.widgetIdForKey(.root, key_header) orelse
        return error.MissingRightHeader;
    try std.testing.expectEqual(left_header, left_again);
    try std.testing.expectEqual(right_header, right_again);

    // The model is still shared, and still reachable without a view pointer.
    var seen: ReadRevision = .{};
    try scenario.revision(ReadRevision, &seen);
    try std.testing.expectEqual(@as(u32, 2), seen.revision);

    // The two Apps hold independent retained tickets: dropping the caller's
    // strong owner still leaves both windows drawing the same live model, and
    // writing through the surviving ticket still updates both.
    const held = try scenario.session.retain(Document, scenario.owner);
    try scenario.session.release(Document, &scenario.owner);
    scenario.owner = held;
    try scenario.bump();
    try scenario.publish(4);
    try std.testing.expectEqualStrings("left r3", scenario.leftLabel());
    try std.testing.expectEqualStrings("right r3", scenario.rightLabel());
}

test "api-w25 the shared model moves once and reaches both SDL dummy windows" {
    var gpa_state: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    defer std.testing.expect(gpa_state.deinit() == 0) catch {};
    const gpa = gpa_state.allocator();

    const headless = try runHeadless(gpa);
    const dummy = try runDummy(gpa);

    // The scenario is not vacuous: the click reached exactly one window and the
    // model advanced once, on both routes.
    try std.testing.expectEqual(@as(u32, 1), headless.left.clicks);
    try std.testing.expectEqual(@as(u32, 0), headless.right.clicks);
    try std.testing.expectEqualStrings("left r2", headless.left.labelSlice());
    try std.testing.expectEqualStrings("right r2", headless.right.labelSlice());
    try std.testing.expectEqual(@as(u32, 1), dummy.left.clicks);
    try std.testing.expectEqual(@as(u32, 0), dummy.right.clicks);
    try std.testing.expectEqualStrings("left r2", dummy.left.labelSlice());
    try std.testing.expectEqualStrings("right r2", dummy.right.labelSlice());

    // The pointer press focused the clicked window's header and no other.
    try std.testing.expect(headless.left.focus_is_header);
    try std.testing.expect(!headless.right.focus_is_header);

    // Both drivers published the same semantic control with the same states.
    try std.testing.expectEqual(
        @as(u8, @backingInt(semantics.Role.button)),
        headless.left.header_role,
    );
    try std.testing.expectEqualStrings("header", headless.left.headerNameSlice());
    try std.testing.expect(headless.left.header_focusable);
    try std.testing.expect(headless.left.header_clickable);
    try std.testing.expect(headless.left.header_focused);

    // The dummy arm reports what it really has: a window with no swapchain and
    // therefore no presentation. A non-zero count here would be a lie.
    try std.testing.expectEqual(@as(u32, 0), dummy.left_facts.frames_presented);
    try std.testing.expectEqual(@as(u32, 0), dummy.right_facts.frames_presented);
    try std.testing.expectEqualStrings("dummy", dummy.mode);

    // The whole point: the two drivers agree, field by field.
    try expectAgreement(&headless, &dummy);
}
