//! W09 gate smoke — the ACTUAL `TodoApp` controls under the real `App` router.
//!
//! `zig build test -Dtest-filter=api-w09` covers the W09 contracts against
//! synthesized trees (`src/v7/w09_contract_test.zig`). This binary mounts the
//! committed demo root `ui.TodoApp`, builds real frames, and drives the real
//! `nogui.App.handle` input path — the same entry the SDL host adapter calls.
//! No window, no `GpuEndpoint`, no SDL, no display server.
//!
//! Five scenarios, each a hard failure, each asserting a MODEL effect of the
//! demo's own state rather than a dispatch result:
//!
//!   A. press / move / release on the counter card's real "inc" button: a
//!      press alone never mutates, every move stays on the press target while
//!      captured, a release away from that target does not activate, a
//!      release with no press does not activate, and one press+release on the
//!      target activates exactly once.
//!   B. `mouse_cancel` on a captured button: the cancel itself is routed to
//!      the captured target, and the release that follows cannot activate.
//!   C. the volume slider dragged out of its track and back: the value follows
//!      the pointer past the track edge (clamped to the slider's own min/max),
//!      returns to a different point inside, and the release ends the capture
//!      so a later move no longer moves it. A rebuild re-binds the same field.
//!   D. key-up for a focused TodoApp checkbox: routed to that checkbox, seen
//!      by the root observer in both capture and bubble, and carrying no text.
//!   E. the Todo rows reordered under a focused checkbox: the focused stable
//!      identity stays on its own model row, and one key press toggles exactly
//!      that row (a repeated key toggles nothing).
//!
//! In the headless gate the only thing this file adds to the demo tree is ONE
//! empty column node owned by the root adapter. Routed events need an ancestor
//! whose `onRoutedEvent` can observe them, and the demo root has none. That
//! node creates no control, binds no model and mutates nothing; every control
//! under test is the one `ui.TodoApp` itself builds.
//!
//! -- Native mode --
//!
//! The second mode mounts the SAME `ui.TodoApp` under the real public host on
//! the caller's own display server and paints every frame through
//! `v7_frame.NativeFrame`. It never pushes an SDL event of its own: every
//! observation is one real `Application.dispatch` of one real platform event,
//! delivered to the App as the same translated event the demo window
//! delivers. An EXTERNAL controller on that server — `xdotool`, `ydotool`, a
//! remote X client — does the pressing, the dragging and the typing.
//!
//! It prints the window title, the SDL window id and every control's committed
//! geometry and device-pixel centre BEFORE it waits for anything, so the
//! controller aims at published numbers and this binary waits on bounded
//! evidence from the real router rather than on a fixed sleep. Each step has
//! its own budget and a step whose evidence never arrives fails the run.
//!
//! The native arm adds exactly ONE control to the tree: an ordinary button
//! whose visible label is the field model's own bytes, registered as a real
//! text endpoint. `ui.TodoApp` ships no editable control and `DrawCtx` has no
//! text-input widget, so a run that claims committed text needs a host for it;
//! that button is that host, and it is the W12 ink module's field, so the
//! glyphs the tree paints and the caret the endpoint publishes are shaped by
//! the one pinned `TextService` rather than by a second one written here.
//!
//! ── The controller protocol ───────────────────────────
//!
//! The run publishes this before it waits, and every coordinate below is read
//! back out of a committed frame. A controller performs ONE action per `step:`
//! line and waits for the next one; the run names the step it is waiting for
//! and fails with a report of what actually arrived if that step's evidence
//! never comes inside its own budget.
//!
//!   protocol: title=... sdl_window_id=N ... screen_origin=(x,y) client=0,0
//!   control: <name> node=N rect=[x,y w h] center=(cx,cy)
//!            device=(dx,dy) screen=(sx,sy)
//!   protocol: slider_outside=(x,y) clamped_to=V start=(x,y) back=(x,y)
//!            expect_text="ok"
//!   ready: ...                 <- the window may be driven from here
//!   step: <name> budget_ms=N mark_records=N mark_commits=N nodes ...
//!
//! Controls, and what each step wants from them:
//!
//!   press_away_down  press on `inc` center
//!   press_away_up    release on `caption_counter` center
//!   valid_down       press on `inc` center
//!   valid_up         release there
//!   valid_settled    nothing; the run watches the counter for 350 ms
//!   slider_down      press at `start`
//!   slider_out       move to `slider_outside`
//!   slider_back      move to `back`
//!   slider_up        release there
//!   slider_released  move to `slider_outside` again; the volume must not move
//!   check_down       press on `todo_buy_milk` center
//!   check_up         release there; the row ticks and takes focus
//!   repeat_down      HOLD space; the run requires ONE activation and NO
//!                    committed text, and reports the platform's own repeat
//!                    count beside the number of distinct key-downs
//!   repeat_up        release space; wait for the server's autorepeat to stop
//!                    before the next step, or it will type into the next one
//!   discrete_settled press and release space twice; each press toggles
//!   field_down       press on `text_field` center
//!   field_up         release there; the endpoint binds and SDL text input starts
//!   text_settled     type exactly `expect_text`, one key per character
//!
//! `center` is window-logical, `device` is window pixels at the reported scale,
//! and `screen` is the absolute point the window really sits at. Use `screen`
//! when it is not `null` and `center` with a window-relative warp when it is.
//!
//! Run it: `zig build w09-controls-smoke`. Add `-- --native` for the bounded
//! native gate on the caller's own display server, and `-- --native --step-ms
//! N` to give every step a different budget.
//! Add `--ppm PATH` in native mode to save the final presented GPU image.
const std = @import("std");
const Io = std.Io;

const nogui = @import("nogui");
const ui = @import("ui.zig");
const sdl3 = @import("sdl3");
const noapi = @import("noapi");
const host = @import("nogui_host");
const frame_api = @import("v7_frame");
/// The repo's one shaped-text field: model, protocol vtable, endpoint and
/// caret geometry, all resolved through the `TextEngine` `NativeFrame` owns.
const ink = @import("w12_ime_ink.zig");

const App = nogui.App;
const DrawCtx = nogui.DrawCtx;
const Event = nogui.Event;
const FrameNodeId = nogui.FrameNodeId;
const FrameOutput = nogui.FrameOutput;
const Rect = nogui.Rect;
const Size = nogui.Size;
const WidgetId = nogui.WidgetId;
const WidgetTree = nogui.WidgetTree;
const DispatchContext = nogui.event.DispatchContext;
const Phase = nogui.event.Phase;
const hitStable = nogui.input.hitStable;
const visualBorderRect = nogui.widget.visualBorderRect;
const NativeFrame = frame_api.NativeFrame;
const contract = host.window_contract;
const Application = host.Application;
/// The demo tree is laid out for a 1100px-wide surface and overflows a short
/// one, so the smoke uses a taller surface. Geometry is read back from each
/// committed frame, never assumed.
const surface: Size = .{ .width = 1400, .height = 1800 };

const Reporter = struct {
    io: Io,
    buffer: [4096]u8 = @splat(0),

    fn emit(self: *Reporter, comptime fmt: []const u8, args: anytype) !void {
        const text = try std.fmt.bufPrint(&self.buffer, fmt, args);
        try Io.File.stdout().writeStreamingAll(self.io, text);
    }
};

/// Report the failing expectation, then fail the run. A smoke whose failure
/// is silent is indistinguishable from a smoke that passed.
fn require(
    comptime fmt: []const u8,
    condition: bool,
    report: *Reporter,
    args: anytype,
) !void {
    if (condition) return;
    try report.emit("FAIL: " ++ fmt ++ "\n", args);
    return error.SmokeAssertionFailed;
}

// --- routed-event observation --------------------------------------------

const Tag = enum {
    mouse_down,
    mouse_move,
    mouse_up,
    mouse_cancel,
    key_down,
    key_up,
    text_input,
    focus_in,
    focus_out,
    capture_lost,
    activate,
    other,
};

fn tagOf(ev: Event) Tag {
    return switch (ev) {
        .mouse_down => .mouse_down,
        .mouse_move => .mouse_move,
        .mouse_up => .mouse_up,
        .mouse_cancel => .mouse_cancel,
        .key_down => .key_down,
        .key_up => .key_up,
        .text_input => .text_input,
        .focus_in => .focus_in,
        .focus_out => .focus_out,
        .capture_lost => .capture_lost,
        .activate => .activate,
        else => .other,
    };
}

/// Whether this key event carried the platform's autorepeat mark. It is the
/// only difference between ONE press held down and MANY discrete presses, so
/// the native arm reports the two counts side by side instead of collapsing
/// them into one number.
fn repeatOf(ev: Event) bool {
    return switch (ev) {
        .key_down => |key| key.repeat,
        .key_up => |key| key.repeat,
        else => false,
    };
}

const Record = struct {
    tag: Tag,
    phase: Phase,
    target: FrameNodeId,
    repeat: bool = false,
};

/// One committed text event, byte for byte as the router delivered it. The
/// event's slice is only borrowed for the dispatch, so the bytes are copied
/// here; the model's own bytes are read separately and compared against this.
const commit_bytes = 64;

const Commit = struct {
    bytes: [commit_bytes]u8 = @splat(0),
    len: u8 = 0,

    fn text(self: *const Commit) []const u8 {
        return self.bytes[0..self.len];
    }
};

const commit_capacity = 128;

/// Fixed capacity: a routed event reaches the root twice (capture, bubble),
/// so the bound is a real budget and an overflow is a reported failure rather
/// than a silent drop. The native arm drives a real controller through every
/// control in the tree, so it needs a larger budget than the headless gate's
/// five scripted scenarios.
const probe_capacity = 4096;

const Probe = struct {
    records: [probe_capacity]Record,
    count: usize = 0,
    overflow: bool = false,
    commits: [commit_capacity]Commit = @splat(.{}),
    commit_count: usize = 0,
    commit_overflow: bool = false,

    fn clear(self: *Probe) void {
        self.count = 0;
        self.overflow = false;
        self.commit_count = 0;
        self.commit_overflow = false;
    }

    fn push(self: *Probe, record: Record) void {
        if (self.count == self.records.len) {
            self.overflow = true;
            return;
        }
        self.records[self.count] = record;
        self.count += 1;
    }

    fn pushCommit(self: *Probe, value: []const u8) void {
        if (self.commit_count == self.commits.len or value.len > commit_bytes) {
            self.commit_overflow = true;
            return;
        }
        var entry: Commit = .{ .len = @intCast(value.len) };
        @memcpy(entry.bytes[0..value.len], value);
        self.commits[self.commit_count] = entry;
        self.commit_count += 1;
    }

    fn find(self: *const Probe, tag: Tag, phase: Phase) ?Record {
        for (self.records[0..self.count]) |record| {
            if (record.tag == tag and record.phase == phase) return record;
        }
        return null;
    }

    fn countTag(self: *const Probe, tag: Tag) usize {
        var total: usize = 0;
        for (self.records[0..self.count]) |record| {
            if (record.tag == tag) total += 1;
        }
        return total;
    }

    /// The records this run pushed at or after `mark`. The native arm marks the
    /// probe at every step boundary, so a step's evidence is exactly the
    /// traffic that arrived while it was the current one.
    fn since(self: *const Probe, mark: usize) []const Record {
        const start = @min(mark, self.count);
        return self.records[start..self.count];
    }

    fn commitsSince(self: *const Probe, mark: usize) []const Commit {
        const start = @min(mark, self.commit_count);
        return self.commits[start..self.commit_count];
    }
};

/// The bytes the native arm's field control draws. A component's draw runs
/// inside a frame and may not borrow the Session, so the pump copies the
/// model's own bytes here between frames and the control's label reads this
/// one value. That is also why the label cannot be a pointer into the model:
/// the model's bytes move on the next commit.
const field_bytes = 48;

const FieldMirror = struct {
    bytes: [field_bytes]u8 = @splat(0),
    len: usize = 0,

    fn text(self: *const FieldMirror) []const u8 {
        return self.bytes[0..self.len];
    }

    /// A value this buffer cannot hold is refused rather than clipped: the
    /// control's label IS the model's bytes, and a clipped label would print
    /// text the model no longer holds.
    fn set(self: *FieldMirror, value: []const u8) bool {
        if (value.len > self.bytes.len) return false;
        @memcpy(self.bytes[0..value.len], value);
        self.len = value.len;
        return true;
    }
};

/// The field control's own box. Its padding and border are read back out of
/// the committed tree before the endpoint's geometry is published, so the
/// caret the input method is given names the field's real content box rather
/// than an authored guess at one.
const field_inset = 6;
const field_vertical_inset = 4;

/// The observation adapter: the committed demo root plus exactly one empty
/// container node owned by the adapter component, so the root component has a
/// routed-event handler to observe with. In the headless gate it builds no
/// control at all.
const ObservedTodo = struct {
    todo: ui.TodoApp = .{},
    probe: *Probe,
    /// Native arm only. Null in the headless gate, which is what keeps that
    /// gate's committed tree exactly the tree it always was.
    field: ?*FieldMirror = null,
    /// The field control's node in the frame that last committed. The control
    /// records its OWN node instead of this run scanning for one: its label is
    /// the model's bytes and changes with every commit, so no static text can
    /// identify it across frames.
    field_node: FrameNodeId = .root,

    pub fn draw(self: *ObservedTodo, ctx: *DrawCtx) !void {
        _ = try ctx.column(.{ .direction = .column, .gap = 0, .grow = 1 });
        defer ctx.pop();
        if (self.field) |mirror| {
            self.field_node = try ctx.button(.{
                .key = .{ .static = "w09-text-field" },
                .label = mirror.text(),
                .visual_label = mirror.text(),
                // The one size the field's own shaped layout uses, so the glyphs
                // this control paints and the caret its endpoint publishes are
                // one measurement of the same bytes.
                .font_size = ink.font_size_f32,
                .justify = .start,
                .@"align" = .center,
                .padding = .{
                    .top = field_vertical_inset,
                    .bottom = field_vertical_inset,
                    .left = field_inset,
                    .right = field_inset,
                },
                .border = .{ .top = 1, .right = 1, .bottom = 1, .left = 1 },
                .color = .{ 0.87, 0.87, 0.92, 1 },
            });
        }
        try ctx.component(ui.TodoApp, .{ .key = .{ .static = "w09-todo" } }, &self.todo);
    }

    pub fn onRoutedEvent(self: *ObservedTodo, route: *DispatchContext) void {
        const event = route.event.*;
        self.probe.push(.{
            .tag = tagOf(event),
            .phase = route.phase,
            .target = route.target,
            .repeat = repeatOf(event),
        });
        // One entry per DELIVERY, not per phase: a routed event reaches this
        // observer in capture and again in bubble, and a commit counted twice
        // would look like two commits of the same bytes.
        if (route.phase == .bubble) {
            switch (event) {
                .text_input => |commit| self.probe.pushCommit(commit.text),
                else => {},
            }
        }
    }
};

// --- tree access ---------------------------------------------------------

fn buttonNode(tree: *const WidgetTree, label: []const u8) ?FrameNodeId {
    for (tree.nodes.items) |node| {
        switch (node.kind) {
            .button => |button| if (std.mem.eql(u8, button.label, label)) return node.id,
            else => {},
        }
    }
    return null;
}

fn checkboxNode(tree: *const WidgetTree, value: *bool) ?FrameNodeId {
    for (tree.nodes.items) |node| {
        switch (node.kind) {
            .checkbox => |box| if (box.value == value) return node.id,
            else => {},
        }
    }
    return null;
}

fn sliderNode(tree: *const WidgetTree, label: []const u8) ?FrameNodeId {
    for (tree.nodes.items) |node| {
        switch (node.kind) {
            .slider => |slider| if (std.mem.eql(u8, slider.label, label)) return node.id,
            else => {},
        }
    }
    return null;
}

/// The slider's model field: the demo binds `.value = &self.volume`, so this
/// pointer IS the model, not a copy of it.
fn sliderBound(tree: *const WidgetTree, id: FrameNodeId) ?*f32 {
    const node = tree.nodeConst(id) orelse return null;
    return switch (node.kind) {
        .slider => |slider| slider.value,
        else => null,
    };
}

fn labelNode(tree: *const WidgetTree, text: []const u8) ?FrameNodeId {
    for (tree.nodes.items) |node| {
        switch (node.kind) {
            .label => |label| if (std.mem.eql(u8, label.text, text)) return node.id,
            else => {},
        }
    }
    return null;
}

/// The field control's own label node: the child the button builds for its
/// visible text. Its committed box is the glyph box the caret has to agree
/// with, so it is read rather than reconstructed from the button's padding.
/// An empty field draws no label at all, which is a real absence and not a
/// control this run cannot find.
fn fieldLabelNode(tree: *const WidgetTree, button: FrameNodeId) ?FrameNodeId {
    const node = tree.nodeConst(button) orelse return null;
    if (node.children.items.len != 1) return null;
    const child = tree.nodeConst(node.children.items[0]) orelse return null;
    return switch (child.kind) {
        .label => child.id,
        else => null,
    };
}

fn center(rect: Rect) [2]f32 {
    return .{ rect.x + rect.w / 2, rect.y + rect.h / 2 };
}

fn near(value: f32, expected: f32, tolerance: f32) bool {
    return @abs(value - expected) <= tolerance;
}

fn stableText(id: ?WidgetId) []const u8 {
    const value = id orelse return "no stable widget";
    return switch (value.slot) {
        0 => "stable slot 0",
        1 => "stable slot 1",
        2 => "stable slot 2",
        else => "another stable slot",
    };
}

// --- rig -----------------------------------------------------------------

const Rig = struct {
    app: *App,
    root: *ObservedTodo,
    probe: *Probe,
    gpa: std.mem.Allocator,
    tick: u32 = 0,

    fn todo(self: *Rig) *ui.TodoApp {
        return &self.root.todo;
    }

    /// One driver frame through the production `handle` entry. The returned
    /// output and its tree stay readable until the next call.
    fn frame(self: *Rig) !FrameOutput {
        self.tick += 1;
        const out = (try self.app.handle(.{
            .frame = .{ .tick = self.tick, .time_ms = @as(u64, self.tick) * 16 },
        })) orelse return error.MissingFrameOutput;
        if (out.json) |json| self.gpa.free(json);
        return out;
    }
};

fn send(rig: *Rig, ev: Event) !void {
    _ = try rig.app.handle(ev);
}

// --- A: press / move / release -------------------------------------------

fn scenarioPointerLifecycle(rig: *Rig, report: *Reporter) !void {
    try report.emit("\n[A] press / move / release on the TodoApp \"inc\" button\n", .{});
    const tree = (try rig.frame()).tree;
    const inc = buttonNode(tree, "inc") orelse return error.MissingCounterInc;
    const inc_node = tree.nodeConst(inc) orelse return error.MissingCounterInc;
    const inc_key = inc_node.widget_id orelse return error.UnstableCounterInc;
    const inc_rect = visualBorderRect(tree, inc);
    const caption = labelNode(tree, "COUNTER") orelse return error.MissingCounterCaption;
    const caption_rect = visualBorderRect(tree, caption);
    try require(
        "the inc button laid out at {d}x{d}",
        inc_rect.w > 0 and inc_rect.h > 0,
        report,
        .{ inc_rect.w, inc_rect.h },
    );
    try require(
        "the COUNTER caption laid out at {d}x{d}",
        caption_rect.w > 0 and caption_rect.h > 0,
        report,
        .{ caption_rect.w, caption_rect.h },
    );

    const on_target = center(inc_rect);
    const off_target = center(caption_rect);
    try require(
        "the inc button centre ({d:.1},{d:.1}) resolves to no stable widget",
        hitStable(tree, on_target) != null,
        report,
        .{ on_target[0], on_target[1] },
    );
    const off_key = hitStable(tree, off_target);
    try require(
        "the off-target point resolves to the inc button itself",
        off_key == null or !off_key.?.eql(inc_key),
        report,
        .{},
    );
    try report.emit("    on ({d:.1},{d:.1}) the inc button; off ({d:.1},{d:.1}) the COUNTER caption ({s})\n", .{
        on_target[0], on_target[1], off_target[0], off_target[1], stableText(off_key),
    });

    rig.probe.clear();
    try send(rig, .{ .mouse_down = .{ .button = .left, .x = on_target[0], .y = on_target[1] } });
    try require("a press alone moved the counter to {d}", rig.todo().counter == 0, report, .{rig.todo().counter});
    try require(
        "the press never reached the root capture phase",
        rig.probe.find(.mouse_down, .capture) != null,
        report,
        .{},
    );

    try send(rig, .{ .mouse_move = .{ .x = off_target[0], .y = off_target[1] } });
    const move = rig.probe.find(.mouse_move, .bubble) orelse return error.MissingObservedMove;
    try require(
        "the move left the press target: routed to node {d} instead of the inc button",
        move.target == inc,
        report,
        .{@backingInt(move.target)},
    );

    try send(rig, .{ .mouse_up = .{ .button = .left, .x = off_target[0], .y = off_target[1] } });
    try require(
        "releasing away from the press target activated the counter: {d}",
        rig.todo().counter == 0,
        report,
        .{rig.todo().counter},
    );

    // A late end with no press must not activate either.
    try send(rig, .{ .mouse_up = .{ .button = .left, .x = on_target[0], .y = on_target[1] } });
    try require(
        "a release with no press activated the counter: {d}",
        rig.todo().counter == 0,
        report,
        .{rig.todo().counter},
    );

    try send(rig, .{ .mouse_down = .{ .button = .left, .x = on_target[0], .y = on_target[1] } });
    try send(rig, .{ .mouse_up = .{ .button = .left, .x = on_target[0], .y = on_target[1] } });
    try require(
        "one press + one release left the counter at {d}, expected exactly 1",
        rig.todo().counter == 1,
        report,
        .{rig.todo().counter},
    );

    const out = try rig.frame();
    const focus = out.focus orelse return error.NoFocusAfterPress;
    try require("the press did not leave focus on the inc button", focus.eql(inc_key), report, .{});
    try require("the route probe overflowed its fixed capacity", !rig.probe.overflow, report, .{});
    try report.emit(
        "    counter 0 -> 0 (press) -> 0 (release away) -> 0 (late end) -> 1 (press+release); focus on \"inc\"\n",
        .{},
    );
}

// --- B: cancel -----------------------------------------------------------

fn scenarioCancel(rig: *Rig, report: *Reporter) !void {
    try report.emit("\n[B] mouse_cancel revokes the capture; the next release cannot activate\n", .{});
    const tree = (try rig.frame()).tree;
    const inc = buttonNode(tree, "inc") orelse return error.MissingCounterInc;
    const point = center(visualBorderRect(tree, inc));
    const before = rig.todo().counter;

    rig.probe.clear();
    try send(rig, .{ .mouse_down = .{ .button = .left, .x = point[0], .y = point[1] } });
    try send(rig, .{ .mouse_cancel = .{ .button = .left, .x = point[0], .y = point[1] } });
    const cancelled = rig.probe.find(.mouse_cancel, .bubble) orelse return error.MissingObservedCancel;
    try require(
        "the cancel was routed to node {d}, not the captured inc button",
        cancelled.target == inc,
        report,
        .{@backingInt(cancelled.target)},
    );

    try send(rig, .{ .mouse_up = .{ .button = .left, .x = point[0], .y = point[1] } });
    try require(
        "a release after cancel activated the counter: {d} -> {d}",
        rig.todo().counter == before,
        report,
        .{ before, rig.todo().counter },
    );
    try report.emit(
        "    cancel reached \"inc\"; the following release left the counter at {d}\n",
        .{rig.todo().counter},
    );
}

// --- C: slider out and back ----------------------------------------------

fn scenarioSliderDrag(rig: *Rig, report: *Reporter) !void {
    try report.emit("\n[C] volume slider: drag out of the track, back inside, then release\n", .{});
    const tree = (try rig.frame()).tree;
    const slider = sliderNode(tree, "volume-slider") orelse return error.MissingVolumeSlider;
    const value = sliderBound(tree, slider) orelse return error.UnboundVolumeSlider;
    const rect = visualBorderRect(tree, slider);
    try require("the volume slider laid out at {d}x{d}", rect.w > 0 and rect.h > 0, report, .{ rect.w, rect.h });

    const y = rect.y + rect.h / 2;
    const start_x = rect.x + rect.w * 0.8;
    const back_x = rect.x + rect.w * 0.25;
    // A point strictly outside the track, still on the surface.
    var out_x: f32 = 0;
    var out_is_left = true;
    if (rect.x >= 60) {
        out_x = rect.x - 60;
        out_is_left = true;
    } else if (rect.x + rect.w + 60 <= surface.width) {
        out_x = rect.x + rect.w + 60;
        out_is_left = false;
    } else {
        return error.NoPointOutsideTheTrack;
    }
    const out_expected: f32 = if (out_is_left) 0 else 1;

    rig.probe.clear();
    try send(rig, .{ .mouse_down = .{ .button = .left, .x = start_x, .y = y } });
    try require(
        "the press at 80% of the track set the volume to {d:.4}",
        near(value.*, 0.8, 0.01),
        report,
        .{value.*},
    );

    try send(rig, .{ .mouse_move = .{ .x = out_x, .y = y } });
    try require(
        "dragging to x={d:.1} outside the track left the volume at {d:.4}, expected the clamped {d:.1}",
        value.* == out_expected,
        report,
        .{ out_x, value.*, out_expected },
    );

    try send(rig, .{ .mouse_move = .{ .x = back_x, .y = y } });
    try require(
        "coming back to 25% of the track left the volume at {d:.4}",
        near(value.*, 0.25, 0.01),
        report,
        .{value.*},
    );

    try send(rig, .{ .mouse_up = .{ .button = .left, .x = back_x, .y = y } });
    try require("the release moved the volume to {d:.4}", near(value.*, 0.25, 0.01), report, .{value.*});
    const released = rig.probe.find(.mouse_up, .bubble) orelse return error.MissingObservedRelease;
    try require(
        "the slider release was routed to node {d}",
        released.target == slider,
        report,
        .{@backingInt(released.target)},
    );

    // The capture ended with the release: a later move outside the track must
    // no longer follow the pointer.
    const rebuilt = try rig.frame();
    const rebound_id = sliderNode(rebuilt.tree, "volume-slider") orelse return error.MissingVolumeSlider;
    const rebound = sliderBound(rebuilt.tree, rebound_id) orelse return error.UnboundVolumeSlider;
    try require("the rebuilt tree bound a different model field", rebound == value, report, .{});
    try require(
        "the rebuilt volume is {d:.4}, expected the dragged 0.25",
        near(rebound.*, 0.25, 0.01),
        report,
        .{rebound.*},
    );

    try send(rig, .{ .mouse_move = .{ .x = out_x, .y = y } });
    try require(
        "a move after the release still drove the slider to {d:.4}; the capture outlived it",
        near(rebound.*, 0.25, 0.01),
        report,
        .{rebound.*},
    );
    try report.emit("    0.8 -> {d:.1} (outside the track) -> 0.25 (back inside) -> held at 0.25 after release\n", .{
        out_expected,
    });
}

// --- D: focused key-up ----------------------------------------------------

fn scenarioFocusedKeyUp(rig: *Rig, report: *Reporter) !void {
    try report.emit("\n[D] key-up reaches the focused TodoApp checkbox\n", .{});
    const tree = (try rig.frame()).tree;
    const first = checkboxNode(tree, &rig.todo().done[0]) orelse return error.MissingFirstTodoCheckbox;
    const point = center(visualBorderRect(tree, first));
    try send(rig, .{ .mouse_down = .{ .button = .left, .x = point[0], .y = point[1] } });
    try send(rig, .{ .mouse_up = .{ .button = .left, .x = point[0], .y = point[1] } });
    try require("the pointer click did not check the first todo row", rig.todo().done[0], report, .{});

    const focused_output = try rig.frame();
    const focus = focused_output.focus orelse return error.NoFocusAfterClick;
    const focused_node = focused_output.tree.frameNode(focus) orelse return error.StaleFocusAfterClick;

    rig.probe.clear();
    try send(rig, .{ .key_down = .{ .key = .space } });
    try require("the focused key-down did not untick the first todo row", !rig.todo().done[0], report, .{});
    try send(rig, .{ .key_up = .{ .key = .space } });

    const up = rig.probe.find(.key_up, .bubble) orelse return error.MissingObservedKeyUp;
    try require(
        "the key-up was routed to node {d}, not the focused checkbox at node {d}",
        up.target == focused_node,
        report,
        .{ @backingInt(up.target), @backingInt(focused_node) },
    );
    try require(
        "the key-up never reached the root capture phase",
        rig.probe.find(.key_up, .capture) != null,
        report,
        .{},
    );
    try require(
        "the key-down reached the root observer {d} times, expected capture + bubble",
        rig.probe.countTag(.key_down) == 2,
        report,
        .{rig.probe.countTag(.key_down)},
    );
    try require(
        "the key-up reached the root observer {d} times, expected capture + bubble",
        rig.probe.countTag(.key_up) == 2,
        report,
        .{rig.probe.countTag(.key_up)},
    );
    try require(
        "a bare key press produced {d} committed text events",
        rig.probe.countTag(.text_input) == 0,
        report,
        .{rig.probe.countTag(.text_input)},
    );
    try require("the key-up toggled the row a second time", !rig.todo().done[0], report, .{});
    try report.emit(
        "    \"buy milk\" focused by pointer; space toggled it once;" ++
            " key-up bubbled to the root observer carrying no text\n",
        .{},
    );
}

// --- E: stable focus and single activation -------------------------------

fn scenarioStableFocus(rig: *Rig, report: *Reporter) !void {
    try report.emit("\n[E] reordering the Todo rows keeps the focused checkbox on its own model row\n", .{});
    const tree = (try rig.frame()).tree;
    const second = checkboxNode(tree, &rig.todo().done[1]) orelse return error.MissingSecondTodoCheckbox;
    const point = center(visualBorderRect(tree, second));
    try send(rig, .{ .mouse_down = .{ .button = .left, .x = point[0], .y = point[1] } });
    try send(rig, .{ .mouse_up = .{ .button = .left, .x = point[0], .y = point[1] } });
    try require("the pointer click did not check the second todo row", rig.todo().done[1], report, .{});

    const before = try rig.frame();
    const focus_before = before.focus orelse return error.NoFocusAfterClick;

    rig.todo().item_order[0] = 1;
    rig.todo().item_order[1] = 0;
    const after = try rig.frame();
    const focus_after = after.focus orelse return error.FocusLostOnReorder;
    try require(
        "reordering the rows changed the focused stable identity",
        focus_after.eql(focus_before),
        report,
        .{},
    );

    const moved = after.tree.frameNode(focus_after) orelse return error.StaleFocusAfterReorder;
    const moved_node = after.tree.nodeConst(moved) orelse return error.StaleFocusAfterReorder;
    switch (moved_node.kind) {
        .checkbox => |box| try require(
            "focus followed the row position instead of the model row",
            box.value == &rig.todo().done[1],
            report,
            .{},
        ),
        else => return error.FocusIsNotACheckbox,
    }
    const other_row = checkboxNode(after.tree, &rig.todo().done[0]) orelse return error.MissingFirstTodoCheckbox;
    try require("the reorder did not actually swap the two rows", other_row != moved, report, .{});

    try send(rig, .{ .key_down = .{ .key = .space } });
    try require("the focused key did not untick its own model row", !rig.todo().done[1], report, .{});
    try require("the focused key unticked the other model row", !rig.todo().done[0], report, .{});

    // A repeated key is observable but must not activate a second time.
    try send(rig, .{ .key_down = .{ .key = .space, .repeat = true } });
    try require("a repeated key toggled the row again", !rig.todo().done[1], report, .{});
    try send(rig, .{ .key_up = .{ .key = .space } });
    try send(rig, .{ .key_up = .{ .key = .space, .repeat = true } });
    try require("a repeated key-up toggled the row", !rig.todo().done[1], report, .{});
    try report.emit(
        "    focus survived the swap on the second model row; one space toggled exactly that row," ++
            " the repeat toggled nothing\n",
        .{},
    );
}

// --- the native arm -------------------------------------------------------
//
// Everything below runs ONLY under `--native`. It opens the real host window
// on the caller's own display server, paints every frame through the public
// frame adapter, and then does nothing but pump: the pointer and key input it
// reacts to arrives from an EXTERNAL controller on that server, arrives as a
// real SDL event, and reaches the App through the same translated event the
// demo window's own event loop delivers. This file never constructs one.

/// The window title the controller aims at. It is exact and stable: the host
/// creates the toplevel with it, and the run reports the title SDL read back.
pub const native_title: [:0]const u8 = "w09-controls-smoke";

/// The native window is the SAME logical surface the headless gate lays out
/// against, so a geometry fact published here is a fact about the same scene
/// the headless gate measured.
const native_width: u32 = 1400;
const native_height: u32 = 1800;

/// How long one step waits for its own evidence before the run fails. The
/// controller owns the timing between steps; this budget only says how long a
/// step that HAS been driven may stay unobserved.
const default_step_ms: u64 = 5_000;
/// How long a settled step watches the model before it calls the model still.
/// A longer settle cannot be needed: the controller drives the next step as
/// soon as this one is reported, so a step that only settles late is a step
/// whose evidence never arrived.
const settle_ms: u64 = 350;

/// The characters the controller protocol types into the field. The run
/// asserts the model's bytes equal exactly these, so a commit delivered twice
/// is a failure rather than a longer string.
const expected_text = "ok";

/// The published control geometry, read back from one committed frame. The
/// controller aims at these numbers; nothing in this run assumes them.
const Published = struct {
    inc: Rect = .{},
    caption: Rect = .{},
    slider: Rect = .{},
    first_todo: Rect = .{},
    field: Rect = .{},
    slider_outside: [2]f32 = .{ 0, 0 },
    slider_outside_is_left: bool = true,
    scale_x: f32 = 1,
    scale_y: f32 = 1,
    /// Where the platform really put the window's client area on the screen.
    /// Null on a backend that keeps no global desktop space; the controller
    /// then aims window-relative, which is what the centres already are.
    origin: ?[2]i32 = null,
};

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

/// The native half of the run: the device, the surface that presents into the
/// real window, and the public frame adapter that owns the text engine, the
/// scene renderer and the Oklab-to-sRGB blit. The App is attached to
/// `adapter.gpuEndpoint()` and measures through `adapter.measurer()`, so the
/// tree's paint, the layout's text metrics and the text the field endpoint
/// publishes all name the same objects.
///
/// TEARDOWN ORDER, which is why this is one value with one `deinit`: the App
/// detaches from the endpoint, then this value goes, then SDL quits. Quitting
/// SDL unloads the Vulkan loader, and a live device would then dispatch
/// through an unmapped page.
const NativeHalf = struct {
    gpu: noapi.Gpu,
    /// The platform surface. The real window and this device both outlive it.
    surface: noapi.Surface,
    adapter: NativeFrame,
    quad_vert: Spv,
    quad_frag: Spv,
    sort_comp: Spv,
    fullscreen_vert: Spv,
    blit_oklab: Spv,

    fn init(
        self: *NativeHalf,
        gpa: std.mem.Allocator,
        io: Io,
        sdl: *sdl3.video.Window,
    ) !void {
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
            // The face every app-owned run is shaped with, and the same one
            // the field endpoint shapes with: one pinned face, no fallback.
            .fonts = &.{.{ .family = "InterVariable", .bytes = @embedFile("InterVariable.ttf") }},
            .shaders = .{
                .quad_vert = self.quad_vert.words,
                .quad_frag = self.quad_frag.words,
                .sort_comp = self.sort_comp.words,
                .fullscreen_vert = self.fullscreen_vert.words,
                .blit_oklab = self.blit_oklab.words,
            },
            .name = "w09_controls_blit_oklab",
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

/// One step of the controller protocol. The name is what the run reports, so
/// a failing step names itself in its own report line.
const Step = enum {
    warmup,
    press_away_down,
    press_away_up,
    valid_down,
    valid_up,
    valid_settled,
    slider_down,
    slider_out,
    slider_back,
    slider_up,
    slider_released,
    check_down,
    check_up,
    repeat_down,
    repeat_up,
    discrete_settled,
    field_down,
    field_up,
    text_settled,
    done,
};

/// Steps that watch the model for a moment instead of waiting for an event.
/// Their budget is the settle window, not the step budget: the controller has
/// already driven them.
fn isSettle(step: Step) bool {
    return switch (step) {
        .valid_settled, .discrete_settled => true,
        else => false,
    };
}

/// A stable identity that names no widget. Every identity below starts here and
/// is filled in by `publish`; nothing before that may resolve a routed target
/// through one.
const no_widget: WidgetId = .{ .owner = 0, .slot = 0, .generation = 0 };

/// A frame-local node id as a plain number, or "?" when the committed tree
/// does not carry it. `{any}` on the enum itself prints Zig's own cast
/// syntax, which is not something a reader of this report has to decode.
fn nodeText(node: ?FrameNodeId) ?u32 {
    const value = node orelse return null;
    return @backingInt(value);
}

const NativeWindow = struct {
    gpa: std.mem.Allocator,
    io: Io,
    session: *nogui.Session,
    app: *App,
    root: *ObservedTodo,
    probe: *Probe,
    application: *Application,
    handle: contract.WindowHandle,
    native: *NativeHalf,
    /// The field model behind the adapter's one editable control.
    ink_field: ink.Ink,
    mirror: FieldMirror = .{},
    report: *Reporter,
    /// How long one step waits for its own evidence.
    step_ms: u64,
    ppm_path: ?[]const u8 = null,
    tick: u32 = 1,
    frames_committed: u32 = 0,
    retries: u32 = 0,
    /// True once this struct owns the device, the surface and the field model,
    /// and after that the host hook and the caller share one release.
    live: bool = false,
    /// The frame accounting, copied out before the adapter goes: the closing
    /// report outlives it.
    stats: NativeFrame.Stats = .{},
    target: noapi.Extent2D = .{ .width = 0, .height = 0 },
    retirements: u32 = 0,
    should_close: bool = false,
    // The control geometry read back from one committed frame.
    published: Published = .{},
    inc_node: FrameNodeId = .root,
    caption_node: FrameNodeId = .root,
    slider_node: FrameNodeId = .root,
    todo_node: FrameNodeId = .root,
    field_node: FrameNodeId = .root,
    // The stable identities read back in `publish`. They are zero until then,
    // and nothing before `ready` may resolve a routed target through one.
    inc_key: WidgetId = no_widget,
    slider_key: WidgetId = no_widget,
    todo_key: WidgetId = no_widget,
    field_key: WidgetId = no_widget,
    /// True once the committed tree has been read back and every stable
    /// identity is known. Nothing before that may act on the step machine.
    ready: bool = false,
    /// The box the endpoint last published, so the model is borrowed for a
    /// geometry change only and not on every pump.
    published_field: ?ink.Geometry = null,
    // The step machine's cursor into the probe.
    step: Step = .warmup,
    mark: usize = 0,
    commit_mark: usize = 0,
    observed_commits: usize = 0,
    deadline_ms: u64 = std.math.maxInt(u64),
    last_commit_ms: u64 = 0,
    /// When the last step completed. The run holds this long so the final
    /// frame and the closing census are real pixels, then closes its own
    /// window: nothing outside this process is going to close it for us.
    done_at_ms: u64 = 0,
    counter_before: u32 = 0,
    counter_after: u32 = 0,
    volume_before: f32 = 0,
    autorepeat_seen: u32 = 0,
    /// The row's state the moment the hold finished, so the discrete presses
    /// that follow can be judged against the toggle the hold did NOT double.
    done_after_hold: bool = false,
    /// Cumulative key events the real router delivered this run, counted over
    /// the WHOLE probe rather than one step's window: a key-down belongs to
    /// the step that saw it, but its activation and its key-up belong to the
    /// steps after it.
    keys_plain: usize = 0,
    keys_repeat: usize = 0,
    keys_up: usize = 0,
    counted_records: usize = 0,
    hold_plain: usize = 0,
    hold_repeat: usize = 0,
    hold_up: usize = 0,
    /// The same counters snapshotted at every step boundary, so a step that
    /// has to judge events which arrived AFTER it started does not re-count the
    /// ones that arrived before.
    mark_plain: usize = 0,
    mark_repeat: usize = 0,
    mark_up: usize = 0,

    fn records(self: *const NativeWindow) []const Record {
        return self.probe.since(self.mark);
    }

    fn commits(self: *const NativeWindow) []const Commit {
        return self.probe.commitsSince(self.commit_mark);
    }

    /// Whether `target` is this control or a node it owns.
    ///
    /// A real press over a button does NOT land on the button's node: the
    /// pointer is over the caption the button built as its child, and the
    /// router names that child. "Routed to the control" therefore means "to
    /// the control or inside it", which is the claim the model actually makes.
    fn withinControl(self: *const NativeWindow, control: ?FrameNodeId, target: FrameNodeId) bool {
        const root = control orelse return true;
        const tree = self.app.tree_ptr orelse return false;
        var cursor = target;
        var guard: usize = 0;
        while (guard < 512) : (guard += 1) {
            if (cursor == root) return true;
            if (cursor == .root) return false;
            const node = tree.nodeConst(cursor) orelse return false;
            cursor = node.parent;
        }
        return false;
    }

    /// Whether the real router delivered this tag in this phase to this
    /// control inside the current step's window. A null control accepts any
    /// target, which is how a step asks "did any pointer phase arrive at all".
    fn seen(self: *const NativeWindow, tag: Tag, phase: Phase, control: ?FrameNodeId) bool {
        for (self.records()) |record| {
            if (record.tag != tag or record.phase != phase) continue;
            if (self.withinControl(control, record.target)) return true;
        }
        return false;
    }

    /// Distinct routed EVENTS of this tag inside the current step's window:
    /// one bubble-phase record per delivery. The capture-phase twin is what
    /// proves an ancestor saw the same event, and is counted on its own.
    fn countTag(self: *const NativeWindow, tag: Tag) usize {
        var total: usize = 0;
        for (self.records()) |record| {
            if (record.tag == tag and record.phase == .bubble) total += 1;
        }
        return total;
    }

    /// Key events split by the platform's own autorepeat mark, so ONE press
    /// held down and MANY discrete presses are never reported as one number.
    fn countKey(self: *const NativeWindow, tag: Tag, repeat: bool) usize {
        var total: usize = 0;
        for (self.records()) |record| {
            if (record.tag == tag and record.phase == .bubble and record.repeat == repeat) total += 1;
        }
        return total;
    }

    /// The node the committed tree gives this stable identity RIGHT NOW. Node
    /// ids are frame-local and the tree is rebuilt every frame, so a routed
    /// target is resolved back through the identity it belongs to.
    fn nodeOf(self: *const NativeWindow, id: WidgetId) ?FrameNodeId {
        const tree = self.app.tree_ptr orelse return null;
        return tree.frameNode(id);
    }

    /// The slider's bound model field. The demo binds `.value = &self.volume`,
    /// so this pointer IS the model the controller is dragging.
    fn volumeValue(self: *NativeWindow) !f32 {
        const tree = self.app.tree_ptr orelse return error.MissingCommittedTree;
        const node = self.nodeOf(self.slider_key) orelse return error.MissingVolumeSlider;
        const bound = sliderBound(tree, node) orelse return error.UnboundVolumeSlider;
        return bound.*;
    }

    fn lastTarget(self: *const NativeWindow, tag: Tag, phase: Phase) ?FrameNodeId {
        var found: ?FrameNodeId = null;
        for (self.records()) |record| {
            if (record.tag == tag and record.phase == phase) found = record.target;
        }
        return found;
    }

    /// Give the machine a budget before the first step is entered. Without it
    /// the warmup would wait forever for a frame the platform never asks for.
    fn armWarmup(self: *NativeWindow) void {
        self.deadline_ms = sdl3.timer.getMillisecondsSinceInit() + self.step_ms;
    }

    fn enter(self: *NativeWindow, step: Step, now: u64, report: *Reporter) !void {
        self.step = step;
        self.mark = self.probe.count;
        self.commit_mark = self.probe.commit_count;
        self.last_commit_ms = now;
        self.mark_plain = self.keys_plain;
        self.mark_repeat = self.keys_repeat;
        self.mark_up = self.keys_up;
        self.deadline_ms = now + if (isSettle(step)) settle_ms else self.step_ms;
        // The node each stable identity resolves to RIGHT NOW. Node ids are
        // frame-local and the tree is rebuilt every frame, so this line is the
        // only place a reader can see which node a routed target is compared
        // against.
        try report.emit(
            "step: {s} budget_ms={d} mark_records={d} mark_commits={d} nodes inc={any} " ++
                "slider={any} todo={any} field={any}\n",
            .{
                @tagName(step),
                self.deadline_ms - now,
                self.mark,
                self.commit_mark,
                nodeText(self.nodeOf(self.inc_key)),
                nodeText(self.nodeOf(self.slider_key)),
                nodeText(self.nodeOf(self.todo_key)),
                nodeText(self.nodeOf(self.field_key)),
            },
        );
    }

    fn todoApp(self: *NativeWindow) *ui.TodoApp {
        return &self.root.todo;
    }

    fn committedTree(self: *NativeWindow) !*const WidgetTree {
        return self.app.tree_ptr orelse error.MissingCommittedTree;
    }

    fn textInputActive(self: *NativeWindow) !bool {
        const managed = try self.application.getWindow(self.handle);
        return managed.native.textInputActive();
    }

    /// One committed frame, one presented image, through the one public frame
    /// adapter. A swapchain that is out of date is retried, bounded, so a
    /// driver that never settles fails the run instead of spinning.
    fn render(self: *NativeWindow) !bool {
        const managed = try self.application.getWindow(self.handle);
        const logical: nogui.geometry.WindowSize = .{
            .width = @floatFromInt(managed.observed.size.width),
            .height = @floatFromInt(managed.observed.size.height),
        };
        if (logical.width <= 0 or logical.height <= 0) return false;
        // The window's OWN observed scale, given to the frame's text engine and
        // to the App's layout alike, so a measured label and a painted glyph are
        // one measurement at any device pixel ratio.
        const viewport: NativeFrame.Viewport = .{
            .logical = logical,
            .device = try deviceExtent(&managed.native.sdl),
            .scale = try managed.observed.pixelScale(),
        };
        var attempts: u32 = 0;
        while (attempts < 8) : (attempts += 1) {
            // SAFETY: `beginFrame` fills it before this iteration reads it, and
            // a refused begin continues without ever reading it.
            var frame: NativeFrame.Frame = undefined;
            if (!try self.native.adapter.beginFrame(&self.native.surface, viewport, &frame)) {
                self.retries += 1;
                continue;
            }
            var recording = true;
            errdefer if (recording) self.native.adapter.cancelFrame(&frame) catch
                @panic("W09 surface recording cancellation failed");

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
            managed.markPresented();
            return true;
        }
        return error.SwapchainNeverSettled;
    }

    fn onFrame(
        context: *anyopaque,
        _: *Application,
        _: *host.ManagedWindow,
        _: nogui.frame_demand.FrameDemand.Work,
    ) anyerror!bool {
        const self: *NativeWindow = @ptrCast(@alignCast(context));
        return self.render();
    }

    /// One routed platform event. This is the production delivery path: the
    /// host translated a REAL SDL event and this hands the translated core
    /// event to the App, exactly as the demo window's own event loop does.
    /// Nothing here constructs an event.
    fn onEvent(context: *anyopaque, _: *Application, value: Application.Event) anyerror!void {
        const self: *NativeWindow = @ptrCast(@alignCast(context));
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
                        self.invalidate();
                        _ = try self.app.handle(event);
                        return;
                    },
                    .key_down => |key| {
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

    /// Ask for the frame that repaints the tree this event changed. The host
    /// draws on demand, so without this the window would keep showing the
    /// pre-input pixels and the run would be reporting against a stale scene.
    fn invalidate(self: *NativeWindow) void {
        const managed = self.application.getWindow(self.handle) catch return;
        managed.demand.invalidateLayout();
    }

    /// Everything that presents INTO this window goes here, in the order the
    /// frame module requires. Idempotent: the host hook runs while the window
    /// is still alive and the caller runs the same release on the way out.
    fn releaseNative(self: *NativeWindow) void {
        if (!self.live) return;
        self.live = false;
        self.stats = self.native.adapter.stats;
        self.target = self.native.adapter.targetExtent();
        self.app.focus_manager.blur(self.app.focusObserver());
        self.ink_field.deinit();
        self.app.detachGpu();
        self.native.deinit(self.gpa);
        self.retirements += 1;
    }

    fn onBeforeClose(context: *anyopaque, managed: *host.ManagedWindow) void {
        _ = managed;
        const self: *NativeWindow = @ptrCast(@alignCast(context));
        self.releaseNative();
    }

    fn frameStats(self: *NativeWindow) NativeFrame.Stats {
        return if (self.live) self.native.adapter.stats else self.stats;
    }

    fn frameTarget(self: *NativeWindow) noapi.Extent2D {
        return if (self.live) self.native.adapter.targetExtent() else self.target;
    }

    /// Copy the field model's own bytes into the mirror the control draws from,
    /// move the endpoint's published geometry onto the control's own content
    /// box, and bind the endpoint to whatever the App says is focused.
    ///
    /// All three run OUTSIDE a frame: a component's draw may not borrow the
    /// Session, and the endpoint must exist before the next frame reads it.
    fn updateField(self: *NativeWindow) !void {
        if (!self.ready) return;
        const tree = self.app.tree_ptr orelse return;
        const field = self.nodeOf(self.field_key) orelse return;
        _ = tree.nodeConst(field);
        const content = nogui.widget.visualContentRect(tree, field);
        const box: ink.Geometry = .{
            .origin_x = content.x,
            .origin_y = content.y,
            .width = @max(content.w, 1),
            .visible_lines = 1,
            .scroll_px = 0,
        };
        if (self.published_field == null or !std.meta.eql(self.published_field.?, box)) {
            try self.publishFieldGeometry(box);
            self.published_field = box;
        }
        if (try ink.state(&self.ink_field)) |state| {
            if (!self.mirror.set(state.text())) return error.FieldTooLongForTheControl;
        }
        const focused = self.app.focus_manager.current orelse return;
        if (focused.eql(self.field_key)) self.app.registerTextEndpoint(self.ink_field.endpoint(self.field_key));
    }
    /// the next shaped layout, the painted glyphs and the caret the input
    /// method is given all read the same rectangle.
    fn publishFieldGeometry(self: *NativeWindow, box: ink.Geometry) !void {
        const Body = struct {
            const Self = @This();
            box: ink.Geometry,
            fn run(model: *ink.Field, context: *anyopaque) anyerror!void {
                const typed: *Self = @ptrCast(@alignCast(context));
                if (std.meta.eql(model.geometry, typed.box)) return;
                model.geometry = typed.box;
                model.revision += 1;
            }
        };
        var exchange: Body = .{ .box = box };
        try self.session.update(ink.Field, self.ink_field.owner, &exchange, Body.run);
    }

    /// Read the committed tree back and publish every coordinate the external
    /// controller needs, in logical units and in device pixels, before this
    /// run waits for anything at all. The controller aims at these numbers;
    /// nothing in this file assumes them.
    fn publish(self: *NativeWindow) !void {
        const tree = try self.committedTree();
        const managed = try self.application.getWindow(self.handle);
        const scale = try managed.observed.pixelScale();

        const inc = buttonNode(tree, "inc") orelse return error.MissingCounterInc;
        const caption = labelNode(tree, "COUNTER") orelse return error.MissingCounterCaption;
        const slider = sliderNode(tree, "volume-slider") orelse return error.MissingVolumeSlider;
        const todo = checkboxNode(tree, &self.todoApp().done[0]) orelse
            return error.MissingFirstTodoCheckbox;
        const field = self.root.field_node;
        _ = tree.nodeConst(field) orelse return error.MissingFieldControl;

        self.inc_node = inc;
        self.caption_node = caption;
        self.slider_node = slider;
        self.todo_node = todo;
        self.field_node = field;
        self.inc_key = (tree.nodeConst(inc) orelse return error.MissingCounterInc).widget_id orelse
            return error.UnstableCounterInc;
        self.slider_key = (tree.nodeConst(slider) orelse return error.MissingVolumeSlider).widget_id orelse
            return error.UnstableVolumeSlider;
        self.todo_key = (tree.nodeConst(todo) orelse return error.MissingFirstTodoCheckbox).widget_id orelse
            return error.UnstableFirstTodoCheckbox;
        self.field_key = (tree.nodeConst(field) orelse return error.MissingFieldControl).widget_id orelse
            return error.UnstableFieldControl;
        self.ready = true;

        self.published = .{
            .inc = visualBorderRect(tree, inc),
            .caption = visualBorderRect(tree, caption),
            .slider = visualBorderRect(tree, slider),
            .first_todo = visualBorderRect(tree, todo),
            .field = visualBorderRect(tree, field),
            .scale_x = scale.x,
            .scale_y = scale.y,
            .origin = if (managed.observed.position) |point|
                [2]i32{ point.x, point.y }
            else
                null,
        };
        const rect = self.published.slider;
        // A point strictly outside the track, still on the surface, chosen the
        // same way the headless gate chooses it.
        if (rect.x >= 60) {
            self.published.slider_outside = .{ rect.x - 60, rect.y + rect.h / 2 };
            self.published.slider_outside_is_left = true;
        } else if (rect.x + rect.w + 60 <= surface.width) {
            self.published.slider_outside = .{ rect.x + rect.w + 60, rect.y + rect.h / 2 };
            self.published.slider_outside_is_left = false;
        } else {
            return error.NoPointOutsideTheTrack;
        }

        const report = self.report;
        // A window-relative coordinate is the protocol; the screen position is
        // reported so a controller that prefers absolute coordinates can use
        // them without guessing.
        const at = managed.observed.position;
        try report.emit(
            "protocol: title=\"{s}\" sdl_window_id={d} logical={d}x{d} pixels={d}x{d} " ++
                "scale={d:.3}x{d:.3} video_driver={s} screen_origin=({any},{any}) client=0,0\n",
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
                if (at) |point| @as(?i32, point.x) else null,
                if (at) |point| @as(?i32, point.y) else null,
            },
        );
        if (self.published.scale_x != 1 or self.published.scale_y != 1) try report.emit(
            "protocol: scale is not 1:1; use the device coordinates, not the logical ones\n",
            .{},
        );
        try self.publishControl("inc", self.inc_node);
        try self.publishControl("caption_counter", self.caption_node);
        try self.publishControl("slider_volume", self.slider_node);
        try self.publishControl("todo_buy_milk", self.todo_node);
        try self.publishControl("text_field", self.field_node);
        try report.emit(
            "protocol: slider_outside=({d:.1},{d:.1}) clamped_to={d:.1} start=({d:.1},{d:.1}) back=({d:.1},{d:.1}) " ++
                "expect_text=\"{s}\"\n",
            .{
                self.published.slider_outside[0],
                self.published.slider_outside[1],
                if (self.published.slider_outside_is_left) @as(f32, 0.0) else @as(f32, 1.0),
                self.published.slider.x + self.published.slider.w * 0.8,
                self.published.slider.y + self.published.slider.h / 2,
                self.published.slider.x + self.published.slider.w * 0.25,
                self.published.slider.y + self.published.slider.h / 2,
                expected_text,
            },
        );
        try report.emit(
            "ready: frames={d} presented={d}; the controller may drive the window now\n",
            .{ self.tick - 1, self.native.adapter.stats.frames_presented },
        );
    }

    /// One control's committed geometry in every unit a controller might aim
    /// in: the window-logical box, the window-relative centre a
    /// `mousemove --window` wants, the device-pixel centre a scaled display
    /// wants, and the absolute screen point a plain `mousemove` wants.
    fn publishControl(self: *NativeWindow, label: []const u8, node: FrameNodeId) !void {
        const tree = try self.committedTree();
        const rect = visualBorderRect(tree, node);
        const point = center(rect);
        const origin = self.published.origin;
        try self.report.emit(
            "control: {s} node={d} rect=[{d:.1},{d:.1} {d:.1}x{d:.1}] center=({d:.1},{d:.1}) " ++
                "device=({d:.1},{d:.1}) screen=({any},{any})\n",
            .{
                label,
                @backingInt(node),
                rect.x,
                rect.y,
                rect.w,
                rect.h,
                point[0],
                point[1],
                point[0] * self.published.scale_x,
                point[1] * self.published.scale_y,
                if (origin) |at|
                    @as(?i32, @as(i32, @intFromFloat(@round(point[0] * self.published.scale_x))) + at[0])
                else
                    null,
                if (origin) |at|
                    @as(?i32, @as(i32, @intFromFloat(@round(point[1] * self.published.scale_y))) + at[1])
                else
                    null,
            },
        );
    }

    /// Everything this run does between two host steps: read the field model,
    /// and let the step machine judge the evidence that arrived.
    fn pump(self: *NativeWindow) !void {
        try self.updateField();
        if (self.probe.commit_count != self.observed_commits) {
            self.observed_commits = self.probe.commit_count;
            self.last_commit_ms = sdl3.timer.getMillisecondsSinceInit();
        }
        if (self.step == .done) {
            if (sdl3.timer.getMillisecondsSinceInit() - self.done_at_ms >= settle_ms) {
                self.should_close = true;
            }
            return;
        }
        self.countKeys();
        _ = try self.advance();
    }

    /// Add this pump's key events to the run's cumulative counters. Repeats are
    /// counted separately from distinct presses, because that difference IS the
    /// claim the hold step makes.
    fn countKeys(self: *NativeWindow) void {
        for (self.probe.records[self.counted_records..self.probe.count]) |record| {
            if (record.phase != .bubble) continue;
            switch (record.tag) {
                .key_down => if (record.repeat) {
                    self.keys_repeat += 1;
                } else {
                    self.keys_plain += 1;
                },
                .key_up => self.keys_up += 1,
                else => {},
            }
        }
        self.counted_records = self.probe.count;
    }

    /// Judge the current step against what the real router delivered since it
    /// was entered. Returns true when the step completed and the machine moved.
    ///
    /// Every branch is a MODEL fact about the demo's own state, read here after
    /// the event that produced it. A step whose evidence never arrives inside
    /// its own budget fails the run with a report of what did arrive.
    fn advance(self: *NativeWindow) !bool {
        const now = sdl3.timer.getMillisecondsSinceInit();
        const report = self.report;
        const todo = self.todoApp();
        const geometry = self.published;
        const inc = self.nodeOf(self.inc_key);
        const slider = self.nodeOf(self.slider_key);
        const todo_box = self.nodeOf(self.todo_key);
        const field = self.nodeOf(self.field_key);
        const volume: f32 = if (self.ready) try self.volumeValue() else 0;

        const next: ?Step = switch (self.step) {
            // ONE committed frame is the whole warmup: the host draws on
            // demand, the tree is committed and painted by the same frame, and
            // nothing about the protocol exists before that one.
            .warmup => if (self.frames_committed >= 1) blk: {
                try self.publish();
                self.counter_before = todo.counter;
                break :blk Step.press_away_down;
            } else null,

            .press_away_down => if (self.seen(.mouse_down, .bubble, inc)) blk: {
                try require(
                    "a real press routed to the \"inc\" button moved the counter to {d}",
                    todo.counter == self.counter_before,
                    report,
                    .{todo.counter},
                );
                break :blk Step.press_away_up;
            } else null,

            .press_away_up => if (self.seen(.mouse_up, .bubble, null)) blk: {
                try require(
                    "a real release activated the counter: {d}",
                    todo.counter == self.counter_before,
                    report,
                    .{todo.counter},
                );
                try require(
                    "the release was not routed to the captured \"inc\" button; it reached node {d}",
                    self.withinControl(inc, self.lastTarget(.mouse_up, .bubble) orelse .root),
                    report,
                    .{@backingInt(self.lastTarget(.mouse_up, .bubble) orelse .root)},
                );
                try report.emit(
                    "    press then release away from \"inc\": the capture carried the release, " ++
                        "the counter stayed at {d}\n",
                    .{todo.counter},
                );
                break :blk Step.valid_down;
            } else null,

            .valid_down => if (self.seen(.mouse_down, .bubble, inc)) blk: {
                try require(
                    "the second real press on \"inc\" moved the counter to {d}",
                    todo.counter == self.counter_before,
                    report,
                    .{todo.counter},
                );
                break :blk Step.valid_up;
            } else null,

            .valid_up => if (self.seen(.mouse_up, .bubble, inc)) blk: {
                self.counter_after = todo.counter;
                try require(
                    "one real press plus one real release left the counter at {d}, expected exactly {d}",
                    self.counter_after == self.counter_before + 1,
                    report,
                    .{ self.counter_after, self.counter_before + 1 },
                );
                break :blk Step.valid_settled;
            } else null,

            .valid_settled => if (now >= self.deadline_ms) blk: {
                try require(
                    "the counter moved to {d} after the release settled, expected exactly {d}",
                    todo.counter == self.counter_after,
                    report,
                    .{ todo.counter, self.counter_after },
                );
                try report.emit(
                    "    press plus release on \"inc\": counter {d} -> {d}, still {d} after {d} ms\n",
                    .{ self.counter_before, self.counter_after, todo.counter, settle_ms },
                );
                break :blk Step.slider_down;
            } else null,

            .slider_down => if (self.seen(.mouse_down, .bubble, slider)) blk: {
                try require(
                    "the real press at 80% of the track set the volume to {d:.4}",
                    near(volume, 0.8, 0.01),
                    report,
                    .{volume},
                );
                break :blk Step.slider_out;
            } else null,

            .slider_out => if (self.seen(.mouse_move, .bubble, slider)) blk: {
                const clamped: f32 = if (geometry.slider_outside_is_left) 0 else 1;
                try require(
                    "dragging to x={d:.1} outside the track left the volume at {d:.4}, expected the clamped {d:.1}",
                    volume == clamped,
                    report,
                    .{ geometry.slider_outside[0], volume, clamped },
                );
                break :blk Step.slider_back;
            } else null,

            .slider_back => if (self.countTag(.mouse_move) >= 1) blk: {
                try require(
                    "coming back to 25% of the track left the volume at {d:.4}",
                    near(volume, 0.25, 0.01),
                    report,
                    .{volume},
                );
                break :blk Step.slider_up;
            } else null,

            .slider_up => if (self.seen(.mouse_up, .bubble, slider)) blk: {
                try require(
                    "the slider release was not routed to the slider; it reached node {d}",
                    self.withinControl(slider, self.lastTarget(.mouse_up, .bubble) orelse .root),
                    report,
                    .{@backingInt(self.lastTarget(.mouse_up, .bubble) orelse .root)},
                );
                try require(
                    "the release moved the volume to {d:.4}",
                    near(volume, 0.25, 0.01),
                    report,
                    .{volume},
                );
                break :blk Step.slider_released;
            } else null,

            .slider_released => if (self.seen(.mouse_move, .bubble, null)) blk: {
                try require(
                    "a move after the release still drove the volume to {d:.4}; the capture outlived it",
                    near(volume, 0.25, 0.01),
                    report,
                    .{volume},
                );
                try report.emit(
                    "    volume 0.8 -> {d:.1} (outside the track) -> 0.25 (back inside) -> held at {d:.4} " ++
                        "after the release; the next real move reached node {d} and moved nothing\n",
                    .{
                        if (geometry.slider_outside_is_left) @as(f32, 0.0) else @as(f32, 1.0),
                        volume,
                        @backingInt(self.lastTarget(.mouse_move, .bubble) orelse .root),
                    },
                );
                break :blk Step.check_down;
            } else null,

            .check_down => if (self.seen(.mouse_down, .bubble, todo_box)) blk: {
                break :blk Step.check_up;
            } else null,

            .check_up => if (self.seen(.mouse_up, .bubble, todo_box)) blk: {
                try require(
                    "the real click did not check the first todo row",
                    todo.done[0],
                    report,
                    .{},
                );
                const focus = self.app.focus_manager.current orelse return error.NoFocusAfterClick;
                try require("the click did not leave focus on that checkbox", focus.eql(self.todo_key), report, .{});
                try report.emit(
                    "    \"buy milk\" checked by a real click and holds focus on its own model row\n",
                    .{},
                );
                break :blk Step.repeat_down;
            } else null,

            .repeat_down => if (self.countKey(.key_down, false) >= 1) blk: {
                try require(
                    "the focused key-down did not untick the first todo row",
                    !todo.done[0],
                    report,
                    .{},
                );
                // The key-up belongs to the NEXT step, so the counters this
                // whole hold is judged against start here.
                self.hold_plain = self.keys_plain;
                self.hold_repeat = self.keys_repeat;
                self.hold_up = self.keys_up;
                break :blk Step.repeat_up;
            } else null,

            .repeat_up => if (self.seen(.key_up, .bubble, todo_box)) blk: {
                const distinct = self.keys_plain - self.hold_plain + 1;
                const released = self.keys_up - self.hold_up;
                self.autorepeat_seen = @intCast(self.keys_repeat - self.hold_repeat);
                // WHAT MAKES A HOLD A HOLD is that no key-up arrived in the
                // middle of it. A backend that marks autorepeat says so on the
                // extra key-downs; one that does not still cannot turn ONE hold
                // into SEVERAL presses, because presses need their own ups.
                try require(
                    "the hold produced {d} key-ups; one hold must produce exactly one",
                    released == 1,
                    report,
                    .{released},
                );
                try require(
                    "the hold produced {d} distinct key-downs, expected one",
                    distinct == 1,
                    report,
                    .{distinct},
                );
                try require(
                    "the key-up was not routed to the focused checkbox at node {d}; it reached node {d}",
                    self.withinControl(todo_box, self.lastTarget(.key_up, .bubble) orelse .root),
                    report,
                    .{
                        @backingInt(todo_box orelse .root),
                        @backingInt(self.lastTarget(.key_up, .bubble) orelse .root),
                    },
                );
                try require(
                    "the key-up never reached the root capture phase",
                    self.seen(.key_up, .capture, null),
                    report,
                    .{},
                );
                try require(
                    "the field model already holds {d} bytes; an autorepeat must not commit text",
                    self.mirror.len == 0,
                    report,
                    .{self.mirror.len},
                );
                try require("the held key toggled the row a second time", !todo.done[0], report, .{});
                try report.emit(
                    "    one held space: key_downs={d} platform_marked_repeats={d} key_ups={d} " ++
                        "routed_text_input={d} committed_text_bytes=0 toggles=1\n",
                    .{ distinct, self.autorepeat_seen, released, self.countTag(.text_input) },
                );
                self.done_after_hold = todo.done[0];
                break :blk Step.discrete_settled;
            } else null,

            .discrete_settled => if (now >= self.deadline_ms) blk: {
                const distinct = self.keys_plain - self.mark_plain;
                const released = self.keys_up - self.mark_up;
                // The controller sends two distinct presses after releasing
                // the hold. Each down/up is counted once; two activations
                // restore the checkbox to the state after the hold.
                try require(
                    "the discrete space presses produced {d} key-downs, expected two",
                    distinct == 2,
                    report,
                    .{distinct},
                );
                try require(
                    "the discrete space presses produced {d} key-ups, expected two",
                    released == 2,
                    report,
                    .{released},
                );
                try require(
                    "two discrete presses left the row at {} after the hold left it at {}, expected two toggles",
                    todo.done[0] == self.done_after_hold,
                    report,
                    .{ todo.done[0], self.done_after_hold },
                );
                try report.emit(
                    "    discrete spaces after the hold: key_downs={d} key_ups={d} platform_marked_repeats={d} " ++
                        "row {} -> {}; every press released and every press toggled\n",
                    .{
                        distinct,
                        released,
                        self.keys_repeat - self.mark_repeat,
                        self.done_after_hold,
                        todo.done[0],
                    },
                );
                break :blk Step.field_down;
            } else null,

            .field_down => if (self.seen(.mouse_down, .bubble, field)) blk: {
                break :blk Step.field_up;
            } else null,

            .field_up => if (self.seen(.mouse_up, .bubble, field)) blk: {
                const focus = self.app.focus_manager.current orelse return error.NoFocusAfterClick;
                try require("the field click did not leave focus on the field", focus.eql(self.field_key), report, .{});
                const endpoint = self.app.textInputManager().focusedId() orelse
                    return error.NoTextEndpointBound;
                try require(
                    "the bound endpoint is not the field's own identity",
                    endpoint.eql(self.field_key),
                    report,
                    .{},
                );
                try require(
                    "SDL is not delivering committed text for the focused window",
                    try self.textInputActive(),
                    report,
                    .{},
                );
                try report.emit(
                    "    field focused by a real click; the endpoint bound to its own identity " ++
                        "and SDL text input is active\n",
                    .{},
                );
                break :blk Step.text_settled;
            } else null,

            .text_settled => if (self.commits().len >= expected_text.len and
                now - self.last_commit_ms >= settle_ms)
            blk: {
                try require(
                    "the field model took {d} commits for a {d}-byte protocol string; a commit must be applied once",
                    self.commits().len == expected_text.len,
                    report,
                    .{ self.commits().len, expected_text.len },
                );
                const state = (try ink.state(&self.ink_field)) orelse return error.FieldModelUnreadable;
                try require(
                    "the model holds \"{s}\" while the router committed \"{s}\"",
                    std.mem.eql(u8, state.text(), expected_text),
                    report,
                    .{ state.text(), expected_text },
                );
                try require(
                    "the control's own label is \"{s}\" while the model holds \"{s}\"",
                    std.mem.eql(u8, self.mirror.text(), state.text()),
                    report,
                    .{ self.mirror.text(), state.text() },
                );
                try report.emit(
                    "    committed text \"{s}\" reached the model in {d} commits " ++
                        "and painted as the field's own label\n",
                    .{ state.text(), self.commits().len },
                );
                break :blk Step.done;
            } else null,

            .done => Step.done,
        };

        if (next) |step| {
            self.step = step;
            if (step == Step.done) {
                self.mark = self.probe.count;
                self.commit_mark = self.probe.commit_count;
                self.done_at_ms = now;
                try report.emit("step: done budget_ms=0\n", .{});
                return true;
            }
            try self.enter(step, now, report);
            return true;
        }
        if (now < self.deadline_ms) return false;
        try self.reportTimeout(now);
        return error.NativeStepTimedOut;
    }

    /// Why a step never completed: what the router delivered, what the model
    /// held, and what the window had committed. A timeout that does not say
    /// these is indistinguishable from a controller that never ran.
    fn reportTimeout(self: *NativeWindow, now: u64) !void {
        const report = self.report;
        try report.emit(
            "timeout: step={s} waited_ms={d} budget_ms={d} frames={d} presented={d}\n",
            .{
                @tagName(self.step),
                now - (self.deadline_ms - if (isSettle(self.step)) settle_ms else self.step_ms),
                if (isSettle(self.step)) settle_ms else self.step_ms,
                self.frames_committed,
                self.native.adapter.stats.frames_presented,
            },
        );
        try report.emit("timeout: model counter={d} volume={d:.4} done0={}\n", .{
            self.todoApp().counter,
            self.todoApp().volume.volume,
            self.todoApp().done[0],
        });
        for (self.records()) |record| {
            try report.emit(
                "timeout: routed {s} phase={s} node={d} repeat={}\n",
                .{ @tagName(record.tag), @tagName(record.phase), @backingInt(record.target), record.repeat },
            );
        }
        for (self.commits()) |commit| {
            try report.emit("timeout: committed \"{s}\"\n", .{commit.text()});
        }
    }

    /// Inked pixels in the Oklab readback of this run's own target, counted
    /// beside the clear colour. This is a readback of what the window showed,
    /// not a re-render and not a model read.
    fn census(self: *NativeWindow) !void {
        const pixels = try self.native.adapter.readTarget();
        const extent = self.native.adapter.targetExtent();
        var total: u32 = 0;
        for (0..extent.height) |y| {
            for (0..extent.width) |x| {
                const at = (y * extent.width + x) * 4;
                if (@abs(pixels[at] - frame_api.scene.oklab_clear[0]) < 0.004 and
                    @abs(pixels[at + 1] - frame_api.scene.oklab_clear[1]) < 0.004 and
                    @abs(pixels[at + 2] - frame_api.scene.oklab_clear[2]) < 0.004) continue;
                total += 1;
            }
        }
        try self.report.emit("pixels: extent={d}x{d} inked={d}\n", .{ extent.width, extent.height, total });
        if (self.ppm_path) |path| {
            try frame_api.writePpm(self.gpa, self.io, path, pixels, extent);
        }
    }
};

// --- the native run -------------------------------------------------------

/// Open the real host window on the caller's own display server, paint it
/// through the public frame adapter, and then wait — bounded, one step at a
/// time — for an external controller to drive real pointer and key input at
/// it. Nothing in this function creates an SDL event.
fn runNative(
    gpa: std.mem.Allocator,
    io: Io,
    session: *nogui.Session,
    app: *App,
    root: *ObservedTodo,
    probe: *Probe,
    report: *Reporter,
    step_ms: u64,
    ppm_path: ?[]const u8,
) !void {
    const application = try gpa.create(Application);
    // Only the allocation is owned before `init` returns. `gpa.destroy` reads
    // nothing, so it is safe over a struct no constructor ever filled, and a
    // plain `defer` means the success path releases through the same two steps
    // an error path does.
    defer gpa.destroy(application);
    application.* = try Application.init(gpa, session, .{
        .app_id = "dev.nogui.w09controls",
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
        return error.NativeWindowIsNotTheCommittedSurface;
    }

    // The device, the surface and the public frame adapter. The window is open
    // first because the surface is created over the window the platform really
    // gave this process.
    // SAFETY: `init` fills the whole struct, and the release below reads it
    // only when `native_live` says that call returned.
    var native: NativeHalf = undefined;
    var native_live = false;
    defer if (native_live) native.deinit(gpa);
    try native.init(gpa, io, &managed.native.sdl);
    native_live = true;

    // The App measures its layout through the engine that rasterizes the
    // glyphs, and paints through the endpoint whose heap the demo's own
    // mandelbrot showcase binds, so the committed tree, the painted scene and
    // the text metrics are one set of objects.
    app.measure = native.adapter.measurer();
    try app.attachGpu(native.adapter.gpuEndpoint());
    var gpu_attached = true;
    defer if (gpu_attached) app.detachGpu();
    root.todo.setGpuDescriptorHeap(native.adapter.textureHeap().handle);

    // The field model behind the adapter's one editable control. It is shaped
    // by the SAME engine the tree measures with and starts empty, so every
    // byte in it arrived through a real commit.

    var window_holder: NativeWindow = .{
        .gpa = gpa,
        .io = io,
        .session = session,
        .app = app,
        .root = root,
        .probe = probe,
        .application = application,
        .handle = handle,
        .native = &native,
        // SAFETY: initialized at its final address below, before hooks can observe it.
        .ink_field = undefined,
        .report = report,
        .step_ms = step_ms,
        .ppm_path = ppm_path,
    };
    // Ink's endpoint user pointer borrows its own address. Initialize it in
    // the final owner rather than copying a live self-referential value.
    try window_holder.ink_field.init(gpa, native.adapter.textEngine(), session, "");
    // The guards above owned the half while this struct was being built. It is
    // whole now, so it owns them: one owner, one release, and no outer flag
    // that has to remember a half it no longer holds.
    native_live = false;
    gpu_attached = false;
    window_holder.live = true;
    root.field = &window_holder.mirror;

    // The close hook and the error path use one release: blur the endpoint,
    // retire the field's layout/model, detach GPU components, then retire the
    // adapter/surface/device while the platform window is still alive.
    defer if (window_holder.live) window_holder.releaseNative();

    application.setHooks(.{
        .context = &window_holder,
        .on_frame = NativeWindow.onFrame,
        .on_event = NativeWindow.onEvent,
        .on_quit_request = NativeWindow.onQuitRequest,
        // The GPU half is retired here, while the window still exists.
        .on_before_close = NativeWindow.onBeforeClose,
    });
    try application.start();

    try report.emit(
        "native: title=\"{s}\" driver={s} surface={d}x{d} step_budget_ms={d} settle_ms={d}\n",
        .{
            native_title,
            sdl3.video.getCurrentDriverName() orelse "<null>",
            native_width,
            native_height,
            step_ms,
            settle_ms,
        },
    );
    try report.emit(
        "native: this run pushed NO SDL event; every routed record below came from an " ++
            "external controller on the caller's display server\n",
        .{},
    );

    managed.demand.requestPresentation();
    window_holder.armWarmup();
    while (application.isRunning() and !window_holder.should_close) {
        if (!try application.step()) break;
        // A platform can close this window from inside that step, and the host
        // hook retires the GPU half before SDL destroys it.
        if (!window_holder.live) break;
        try window_holder.pump();
        try Io.sleep(io, Io.Duration.fromMilliseconds(2), .real);
    }

    // The pixels of the last presented frame, read back out of the target the
    // two passes wrote. A window the platform closed during the hold already
    // retired the adapter, so the run says so instead of reaching into a
    // released one.
    if (!window_holder.live) {
        try report.emit("pixels: the window was retired during the hold\n", .{});
    } else if (window_holder.frames_committed != 0) {
        try window_holder.census();
    } else {
        try report.emit("pixels: no frame was presented, so there are no pixels to read\n", .{});
    }

    const stats = window_holder.frameStats();
    const target = window_holder.frameTarget();
    try report.emit(
        "holding: frames={d} presented={d} retries={d} records={d} commits={d} overflow={} step={s}\n",
        .{
            window_holder.frames_committed,
            stats.frames_presented,
            window_holder.retries,
            probe.count,
            probe.commit_count,
            probe.overflow or probe.commit_overflow,
            @tagName(window_holder.step),
        },
    );
    try report.emit(
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
    try report.emit("model: counter={d} volume={d:.4} done0={}\n", .{
        root.todo.counter,
        try window_holder.volumeValue(),
        root.todo.done[0],
    });

    if (probe.overflow or probe.commit_overflow) return error.ProbeOverflowed;
    if (window_holder.step != .done) return error.NativeStepsIncomplete;

    // The explicit close goes through the host, so the hook retires the GPU
    // half while the window is still alive.
    if (window_holder.live) {
        const closed = try application.closeWindow(handle);
        _ = try application.step();
        try report.emit("close: released={} window_count={d}\n", .{ closed, application.window_count });
    } else {
        try report.emit("close: the platform closed this window during the hold\n", .{});
    }
    try report.emit("retire: surface_before_window={d} frames_at_retire={d}\n", .{
        window_holder.retirements,
        window_holder.frameStats().frames_presented,
    });
    try report.emit("field: bytes=\"{s}\" commits={d}\n", .{
        window_holder.mirror.text(),
        probe.commit_count,
    });

    // The App outlives this function: `main` owns it and releases it after the
    // host has gone, so the Session still knows its registration while the
    // ordered guards above unwind.
}

// --- entry ----------------------------------------------------------------

pub fn main(init: std.process.Init) !void {
    var gpa_state: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var io_impl: Io.Threaded = .init(gpa, .{});
    defer io_impl.deinit();
    const io = io_impl.io();

    // The window is opt-in. A run with no `--native` never initializes SDL's
    // video, never creates a toplevel and never touches the compositor, so the
    // default is safe on a machine with no display server at all.
    var native = false;
    var step_ms: u64 = default_step_ms;
    var ppm_path: ?[]const u8 = null;
    var args_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args_it.deinit();
    _ = args_it.next();
    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--native")) {
            native = true;
        } else if (std.mem.eql(u8, arg, "--step-ms")) {
            step_ms = try std.fmt.parseInt(u64, args_it.next() orelse return error.MissingStepMs, 10);
            if (step_ms == 0) return error.ZeroStepBudget;
        } else if (std.mem.eql(u8, arg, "--ppm")) {
            ppm_path = args_it.next() orelse return error.MissingPpmPath;
        } else {
            std.log.err("unknown argument: {s}", .{arg});
            return error.UnknownArgument;
        }
    }
    if (!native and ppm_path != null) return error.PpmRequiresNative;

    var report: Reporter = .{ .io = io };
    if (native) {
        try report.emit(
            "W09 TodoApp control smoke — native: real host window, real NativeFrame, external controller\n",
            .{},
        );
    } else {
        try report.emit(
            "W09 TodoApp control smoke — headless, no window, no GPU endpoint, no SDL\n",
            .{},
        );
    }

    var session = try nogui.Session.init(gpa);
    defer session.deinit() catch @panic("W09 control smoke left the Session live");
    var probe: Probe = .{
        // SAFETY: only records[0..count] and commits[0..commit_count] are ever
        // read, and push writes a record before it grows count.
        .records = undefined,
    };
    var root: ObservedTodo = .{ .probe = &probe };
    // The App is owned here in both modes: the native run borrows it for the
    // host's window and gives it back before it returns.
    var app = try App.init(gpa, &session);
    defer app.deinit();
    try app.mountRoot(ObservedTodo, &root);

    if (native) {
        try runNative(gpa, io, &session, &app, &root, &probe, &report, step_ms, ppm_path);
    } else {
        try runHeadless(gpa, &app, &root, &probe, &report);
    }
}

/// The headless gate: the real demo tree under the real `App.handle` entry,
/// with no window, no `GpuEndpoint`, no SDL and no display server.
fn runHeadless(
    gpa: std.mem.Allocator,
    app: *App,
    root: *ObservedTodo,
    probe: *Probe,
    report: *Reporter,
) !void {
    _ = try app.handle(.{ .resize = .{ .width = surface.width, .height = surface.height } });
    var rig: Rig = .{ .app = app, .root = root, .probe = probe, .gpa = gpa };
    try report.emit(
        "surface {d}x{d}; mounted root is the committed demo TodoApp\n",
        .{ surface.width, surface.height },
    );

    try scenarioPointerLifecycle(&rig, report);
    try scenarioCancel(&rig, report);
    try scenarioSliderDrag(&rig, report);
    try scenarioFocusedKeyUp(&rig, report);
    try scenarioStableFocus(&rig, report);

    try report.emit("\nW09 TodoApp control smoke: every scenario passed\n", .{});
}
