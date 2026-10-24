//! App — frame construction, mounted root, and input dispatch.
//!
//! A failed frame keeps the committed tree and input alive. A successful
//! root replacement revokes dispatch immediately while frame arena snapshots
//! remain readable through their documented lifetime.
const std = @import("std");
const tracy = @import("tracy");
const noapi = @import("noapi");

const FrameNodeId = @import("id.zig").FrameNodeId;
const WidgetId = @import("id.zig").WidgetId;
const ComponentKey = @import("key.zig").ComponentKey;
const IdentityRegistry = @import("identity.zig").IdentityRegistry;
const ComponentId = @import("key.zig").ComponentId;
const Component = @import("component.zig").Component;
const ComponentEntry = @import("component.zig").ComponentEntry;
const ComponentRegistry = @import("component.zig").ComponentRegistry;
const GpuEndpoint = @import("runtime.zig").GpuEndpoint;
const GpuFrame = @import("runtime.zig").GpuFrame;
const widget = @import("widget.zig");
const WidgetTree = widget.WidgetTree;
const Size = widget.Size;
const DrawCtx = @import("drawctx.zig").DrawCtx;
const ScrollState = @import("widget.zig").ScrollState;
const overlay = @import("overlay.zig");
const layout = @import("layout/root.zig");
const Event = @import("event.zig").Event;
const Visibility = @import("style.zig").Visibility;
const element = @import("element.zig");
const KeyEvent = @import("event.zig").KeyEvent;
const WidgetNode = @import("widget.zig").WidgetNode;
const event = @import("event.zig");
const input = @import("input.zig");
const headless = @import("headless.zig");
const focus = @import("focus.zig");
const text_input = @import("text_input.zig");
const animation = @import("animation.zig");
const scroll_api = @import("scroll.zig");
const semantics = @import("semantics.zig");
const StateDir = @import("state.zig").StateDir;
const perf_counters = @import("perf_counters.zig");
const CounterSink = perf_counters.CounterSink;
const Session = @import("session.zig").Session;
const Model = @import("model.zig").Model;
const ErasedModel = @import("model.zig").ErasedModel;
const ErasedWeakModel = @import("model.zig").ErasedWeakModel;
const model_type = @import("model.zig");
const Token = @import("subscription.zig").Token;
const action_mod = @import("action.zig");
const keymap = @import("keymap.zig");
const frame_demand = @import("frame_demand.zig");
const Clock = @import("clock.zig").Clock;

const FrameOutput = headless.FrameOutput;
const ComponentMap = std.AutoHashMapUnmanaged(FrameNodeId, Component);

/// Exactly the text a held chord can name: the keymap buffers at most
/// `max_pending_events` events and copies at most `max_input_bytes` into
/// each one, so this store holds a captured chord with nothing truncated.
const max_held_text = keymap.max_pending_events * keymap.max_input_bytes;

pub const App = struct {
    gpa: std.mem.Allocator,
    session: *Session,
    window: u64,
    /// App owns an independent ticket when the root draws a shared model.
    root_model: ?ErasedModel = null,
    root_model_weak: ?ErasedWeakModel = null,
    layout_storage: layout.LayoutStorage,
    /// Serialize the frame tree to JSON (FrameOutput.json). OFF by
    /// default — the windowed + frames modes never read the JSON, and the
    /// serialization is a measurable per-frame cost. The headless drivers
    /// (--sim, --layout, the demo frames) turn it on.
    serialize_json: bool = false,
    /// Dense owners for the last committed tree only.
    components: ComponentMap = .empty,
    /// Committed stable component mounts and keyed widget reservations.
    identity_registry: ComponentRegistry,
    widget_identities: IdentityRegistry,
    /// Persistent scalar timelines keyed by this App's stable widget owner.
    animations: animation.Registry,
    /// Advances only when a frame is published.
    frame_generation: u64 = 0,
    /// The build arena is reset per attempt; the other arena retains the
    /// current committed tree until a successful replacement. Callers may
    /// inspect the old and current trees through their documented lifetimes.
    arenas: [2]std.heap.ArenaAllocator,
    /// Index of the arena holding the most recently built tree.
    current: u32 = 0,
    /// The most recently built tree (in arenas[current]).
    tree_ptr: ?*WidgetTree = null,
    /// Optional borrowed publisher; preparation failure aborts this frame.
    /// Null performs no semantic build or publication.
    semantic_publication: ?semantics.Publication = null,
    /// Candidate identity lookup is exposed only during the annotation hook.
    semantic_tree: ?*const WidgetTree = null,
    /// Optional host text measurer for the canonical layout dispatcher.
    /// The context is the host's own value — a `TextMeasurer` or a
    /// `NodeMeasurer` bound to a stable service — never a thread-local engine.
    /// Null keeps the synthetic layout-only fallback and its goldens.
    measure: ?layout.MeasureSource = null,
    /// The previous frame's state directory — pointers into the arena that
    /// is NOT being rebuilt this frame, so they stay valid while the new
    /// frame builds. state() seeds from these. Swapped to the new frame's
    /// directory at the end of frame(); the old directory dies with its
    /// arena two frames later.
    state_prev: ?*StateDir = null,
    // --- driver-owned input state (mutated by handle(); read at present) ---
    /// The surface size the next frame draws against (set by .resize or
    /// the driver's initial size).
    surface: Size = .{ .width = 800, .height = 600 },
    /// Last cursor position in logical window coordinates (null while outside).
    mouse_pos: ?[2]f32 = null,
    /// Stable focus and per-pointer capture are reconciled on publication.
    focus_manager: focus.Manager = .{},
    focus_observer: ?focus.Observer = null,
    /// Borrowed model endpoint for the currently focused editable widget.
    text_input: text_input.Manager,
    /// Transient routing state during dispatch and frame publication.
    routing_tree: ?*const WidgetTree = null,
    routing_components: ?*const ComponentMap = null,
    /// The component already delivered to in the running dispatch phase.
    /// One component sees one delivery per phase, at the outermost node it
    /// owns during capture and the innermost one during bubble.
    routing_owner: ?FrameNodeId = null,
    routing_phase: ?event.Phase = null,
    publishing_tree: ?*const WidgetTree = null,
    publishing_components: ?*const ComponentMap = null,
    pending_focus_change: ?focus.Change = null,
    // SAFETY: only entries before pending_cancellation_count are read.
    pending_cancellations: [16]focus.Cancellation = undefined,
    pending_cancellation_count: u8 = 0,
    cancellation_routed: bool = false,
    /// A publication cannot write a model, so a chord held by the consumer
    /// leaving the tree waits here until the frame closes. The endpoint that
    /// owns the keyboard stays registered across the wait, so those events
    /// reach the consumer that received them and nobody else.
    // SAFETY: only events before held_len are read; captureHeldReplay fills them.
    held_events: [keymap.max_pending_events]Event = undefined,
    held_len: u8 = 0,
    /// Captured text is copied, never borrowed: the keymap reuses a buffered
    /// event's bytes as soon as another event arrives, and a listener may
    /// inject input between the publication and the delivery. A captured
    /// event's text therefore names a range inside this store.
    // SAFETY: only bytes before held_text_len are written and read.
    held_text: [max_held_text]u8 = undefined,
    held_text_len: usize = 0,
    /// The focus change whose endpoint teardown waits for held_events.
    deferred_focus: ?focus.Change = null,
    /// The tree and dense owners a deferred focus change still has to name.
    /// The widget that lost the keyboard lives in the tree this publication
    /// replaced, so both are retained until the held input reached the
    /// endpoint that change retires.
    deferred_focus_tree: ?*const WidgetTree = null,
    deferred_components: ComponentMap = .empty,
    /// True between ending a frame and completing the input that frame
    /// deferred. A frame requested in that window is refused: it would reset
    /// the arena holding the tree the deferred focus_out must still name.
    settling: bool = false,
    /// Suppresses demo-global shortcuts after a focused consumer handles input.
    last_input_default_prevented: bool = false,
    /// Optional borrowed shortcut services. The caller keeps both alive
    /// until App deinit (or detaches them); no per-frame map is allocated.
    shortcuts: ?struct {
        map: *keymap.Keymap,
        actions: *action_mod.Registry,
    } = null,
    shortcut_contexts: []const []const u8 = &.{},
    shortcut_context_token: u64 = 0,
    /// Visual press state follows the left pointer's capture.
    pressed: ?WidgetId = null,
    /// Display state sampled from the same per-widget animation registry
    /// exposed to custom components. Semantic pressed/hover remain immediate.
    press_alpha: f32 = 0,
    hover_alpha: f32 = 0,
    press_visual: ?WidgetId = null,
    hover_visual: ?WidgetId = null,
    last_time_ms: u64 = 0,
    /// The caller-owned overlay frame this App resolves against the tree it
    /// publishes. Null keeps pointer routing exactly as a tree without
    /// placements. The frame records are the consumer's; App only resolves,
    /// and a frame whose placements name another tree routes nothing.
    overlay: ?*overlay.Frame = null,
    /// The optional renderer endpoint. The endpoint remains owned by the
    /// window driver; App only borrows it while dispatching hooks.
    gpu_endpoint: ?*GpuEndpoint = null,
    /// Optional runner-owned performance counter sink. The disabled build
    /// stores no state and compiles every add to a no-op.
    counter_sink: CounterSink = CounterSink.init(null),

    pub fn init(gpa: std.mem.Allocator, session: *Session) !App {
        const window = try session.registerApp();
        const identities = IdentityRegistry.init(gpa);
        return .{
            .gpa = gpa,
            .session = session,
            .window = window,
            .text_input = text_input.Manager.init(gpa, session),
            .layout_storage = layout.LayoutStorage.init(gpa),
            .identity_registry = ComponentRegistry.init(gpa),
            .widget_identities = identities,
            .animations = animation.Registry.init(gpa, identities.owner),
            .arenas = .{
                std.heap.ArenaAllocator.init(gpa),
                std.heap.ArenaAllocator.init(gpa),
            },
        };
    }

    /// Mount a caller-owned overlay frame. The consumer fills `records` during
    /// its draw; App resolves them against the tree it publishes each frame.
    /// The frame must outlive this App, or be detached with null first.
    pub fn setOverlayFrame(self: *App, overlay_frame: ?*overlay.Frame) void {
        self.overlay = overlay_frame;
    }

    /// The overlay frame this App resolves, or null when none is mounted.
    pub fn overlayFrame(self: *const App) ?*const overlay.Frame {
        return self.overlay;
    }

    /// The node a pointer at `point` reaches on the committed tree: this
    /// frame's topmost placement first, then the tree's own hit test. Every
    /// pointer site routes through this one answer, so a press and the release
    /// that must match it can never disagree.
    fn hitNode(self: *const App, tree: *const WidgetTree, point: [2]f32) ?FrameNodeId {
        if (self.overlay) |overlay_frame| return overlay_frame.hitTestTotal(tree, point);
        return input.hitTest(tree, point);
    }

    /// The stable handle pointer routing reaches at `point`, over the same
    /// start node as `hitNode`.
    fn hitStableNode(self: *const App, tree: *const WidgetTree, point: [2]f32) ?WidgetId {
        if (self.overlay) |overlay_frame| return overlay_frame.hitStableTotal(tree, point);
        return input.hitStable(tree, point);
    }

    pub fn textInputManager(self: *App) *text_input.Manager {
        return &self.text_input;
    }

    /// Attach caller-owned bindings and a registry from this App's Session.
    /// Both services must outlive this App, unless detached first.
    pub fn attachShortcuts(self: *App, map: *keymap.Keymap, actions: *action_mod.Registry) !void {
        if (self.shortcuts != null) return error.ShortcutsAlreadyAttached;
        if (actions.session != self.session) return error.ActionRegistrySessionMismatch;
        self.shortcuts = .{ .map = map, .actions = actions };
    }

    /// Flush deferred defaults under the old context before changing scope.
    /// Context strings and the slice itself stay caller-owned.
    pub fn setShortcutContexts(self: *App, contexts: []const []const u8) !void {
        try self.flushShortcuts();
        self.shortcut_contexts = contexts;
        self.shortcut_context_token +%= 1;
    }

    /// End the borrow even when replaying a held chord is refused.
    pub fn detachShortcuts(self: *App) !void {
        defer self.shortcuts = null;
        try self.flushShortcuts();
    }

    pub fn nextShortcutDeadline(self: *const App) ?i96 {
        const bindings = self.shortcuts orelse return null;
        return bindings.map.nextDeadline();
    }

    pub fn nextShortcutWaitMilliseconds(self: *const App) ?u31 {
        const bindings = self.shortcuts orelse return null;
        const deadline = bindings.map.nextDeadline() orelse return null;
        return frame_demand.taskDeadlineWaitMilliseconds(bindings.map.clock.now(), deadline);
    }

    /// Resolve pending chords even when no new SDL event arrives.
    pub fn tickShortcuts(self: *App) !void {
        const bindings = self.shortcuts orelse return;
        const tree = self.tree_ptr orelse return;
        var dispatch: ShortcutDispatch = .{ .app = self, .tree = tree };
        bindings.map.tick(dispatch.sink());
        try dispatch.finish();
    }

    fn shortcutFocusToken(self: *const App) u64 {
        const id = self.focus_manager.current orelse return 0;
        return (@as(u64, id.slot) << 32) | id.generation;
    }

    fn shortcutScope(self: *const App) keymap.Scope {
        return .{
            .contexts = self.shortcut_contexts,
            .focus_token = self.shortcutFocusToken(),
            .context_token = self.shortcut_context_token,
        };
    }

    fn flushShortcuts(self: *App) !void {
        const bindings = self.shortcuts orelse return;
        const tree = self.tree_ptr orelse return;
        var dispatch: ShortcutDispatch = .{ .app = self, .tree = tree };
        bindings.map.focusChanged(dispatch.sink());
        try dispatch.finish();
    }

    /// Take a held chord out of the keymap without delivering it, so the
    /// events reach their endpoint as soon as the frame closes. True when
    /// input was held. No step after publication can fail, and every frame
    /// entry settles what it captures, so the state asserted here is always
    /// empty on entry.
    fn captureHeldChord(self: *App) bool {
        const bindings = self.shortcuts orelse return false;
        if (bindings.map.nextDeadline() == null) return false;
        std.debug.assert(self.held_len == 0);
        std.debug.assert(self.deferred_focus == null);
        self.held_len = 0;
        self.held_text_len = 0;
        bindings.map.focusChanged(.{
            .user = self,
            .on_replay = captureHeldReplay,
            .on_action = dropHeldAction,
        });
        return self.held_len != 0;
    }

    /// Deliver the input a publication captured, then finish the focus change
    /// that waited for it. Runs after the Session frame closed and before any
    /// listener, with listener delivery suspended: an endpoint that writes its
    /// model here must not reach a listener while the endpoint owning the
    /// keyboard is still the one that input belongs to.
    ///
    /// focus_out routes AFTER the delivery, against the tree and dense owners
    /// this publication replaced — only they can still name the widget that
    /// lost the keyboard — so a consumer that releases its endpoint when it
    /// hears focus_out cannot swallow input it already received.
    fn settleDeferredInput(self: *App) !void {
        const change = self.deferred_focus orelse return;
        self.deferred_focus = null;
        const retired_tree = self.deferred_focus_tree;
        self.deferred_focus_tree = null;
        std.debug.assert(!self.settling);
        self.settling = true;
        self.session.holdDelivery();
        defer {
            self.settling = false;
            self.session.resumeDelivery();
        }
        const count = self.held_len;
        self.held_len = 0;
        // The captured events name ranges in held_text, which nothing writes
        // until the next capture, so the store can already look empty here.
        self.held_text_len = 0;
        // Only the endpoint half of the default runs here. The App-level key
        // default belongs to the tree this event was routed against, and the
        // publication already replaced that tree, so a widget that left it
        // must not act on it.
        var failure: ?anyerror = null;
        var index: u8 = 0;
        while (index < count) : (index += 1) {
            const held = self.held_events[index];
            if (self.text_input.handle(&held)) |outcome| {
                if (outcome != .ignored) self.last_input_default_prevented = true;
            } else |err| {
                failure = err;
                break;
            }
        }
        // The change completes even when a consumer rejected the input, so
        // that endpoint always retires and the new focus never inherits it.
        self.text_input.reconcile(change.current);
        if (retired_tree) |tree| {
            self.routeFocusOutIn(tree, &self.deferred_components, change);
        }
        if (self.routeFocusIn(change)) self.reportFocusChange(change);
        self.deferred_components.clearRetainingCapacity();
        if (failure) |err| return err;
    }

    /// Publish one frame, then finish the input work a publication deferred.
    /// The Session accepts a model write only after the frame closes, so a
    /// chord held by a consumer that left the tree lands here, once, in the
    /// consumer that received it — and it lands before any listener can
    /// inject input, move the focus or start another frame. A consumer that
    /// rejects that write fails this call after the frame is already on the
    /// GPU; nothing is replayed to the consumer that took the keyboard.
    fn presentAndSettle(
        self: *App,
        frame_number: u32,
        time_ms: u64,
        surface: Size,
        gpu_frame: ?*GpuFrame,
    ) !FrameOutput {
        errdefer self.session.pumpListeners();
        const output = try self.present(frame_number, time_ms, surface, gpu_frame);
        errdefer if (output.json) |json| self.gpa.free(json);
        try self.settleDeferredInput();
        self.session.pumpListeners();
        return output;
    }

    fn defaultShortcutInput(self: *App, tree: *const WidgetTree, ev: Event) !void {
        // Routing already happened for this original event. Replay runs ONLY
        // text/default behavior, not routeFocused or another keymap pass.
        switch (ev) {
            .key_down => |key| {
                if (try self.text_input.handle(&ev) != .ignored) {
                    self.last_input_default_prevented = true;
                    return;
                }
                if (self.tree_ptr == tree) self.handleKey(tree, key);
            },
            .text_input => {
                if (try self.text_input.handle(&ev) != .ignored)
                    self.last_input_default_prevented = true;
            },
            .key_up => {},
            else => unreachable,
        }
    }

    const ShortcutDispatch = struct {
        app: *App,
        tree: *const WidgetTree,
        failure: ?anyerror = null,

        fn sink(self: *ShortcutDispatch) keymap.Sink {
            return .{ .user = self, .on_replay = onReplay, .on_action = onAction };
        }

        fn onReplay(raw: *anyopaque, replay: keymap.Replay) void {
            const self: *ShortcutDispatch = @ptrCast(@alignCast(raw));
            if (self.failure != null) return;
            self.app.defaultShortcutInput(self.tree, replay.input) catch |err| {
                self.failure = err;
            };
        }

        fn onAction(raw: *anyopaque, matched: keymap.Action) void {
            const self: *ShortcutDispatch = @ptrCast(@alignCast(raw));
            if (self.failure != null) return;
            const bindings = self.app.shortcuts orelse return;
            _ = bindings.actions.dispatch(
                self.tree,
                self.app.focus_manager.current,
                matched.name,
                null,
            ) catch |err| {
                self.failure = err;
            };
        }

        fn finish(self: *const ShortcutDispatch) !void {
            if (self.failure) |err| return err;
        }
    };

    /// A publication focus change records itself instead of reporting at
    /// once. That lets the caller end held input against the endpoint that
    /// still owns the keyboard, then report the change once the frame has
    /// closed, so the losing consumer never inherits a stale endpoint.
    const PublicationFocus = struct {
        app: *App,
        change: ?focus.Change = null,

        fn onFocus(user: *anyopaque, value: focus.Change) void {
            const self: *PublicationFocus = @ptrCast(@alignCast(user));
            self.change = value;
        }

        fn onCancel(user: *anyopaque, cancellation: focus.Cancellation) void {
            const self: *PublicationFocus = @ptrCast(@alignCast(user));
            onCaptureCancelled(self.app, cancellation);
        }
    };

    /// Only the focused widget can bind a text endpoint; other widgets stay inert.
    pub fn registerTextEndpoint(self: *App, endpoint: text_input.Endpoint) void {
        const focused = self.focus_manager.current orelse return;
        if (focused.eql(endpoint.id)) self.text_input.register(endpoint);
    }

    /// Start a timeline only for a committed keyed widget. Direct draw code
    /// samples it through DrawCtx.animationValue without mutating the attempt.
    pub fn startAnimation(
        self: *App,
        key: animation.Key,
        spec: animation.Spec,
        now_ms: u64,
    ) !void {
        if (!self.session.hasWindow(self.window)) return error.UnknownWindow;
        if (!self.widget_identities.isLive(key.owner)) return error.UnknownWidget;
        try self.animations.start(key, spec, now_ms);
        try self.session.requestRedraw(self.window);
    }

    /// Replace a running plan on a committed keyed widget, starting from the
    /// value the interrupted timeline holds at `now_ms`. A host interruption
    /// (a second gesture, a pointer leaving mid-ease, a new theme token)
    /// must continue from what the user could see; `spec.from` is only a
    /// fallback for a key that is not running.
    pub fn interruptAnimation(
        self: *App,
        key: animation.Key,
        spec: animation.Spec,
        now_ms: u64,
    ) !void {
        if (!self.session.hasWindow(self.window)) return error.UnknownWindow;
        if (!self.widget_identities.isLive(key.owner)) return error.UnknownWidget;
        try self.animations.interrupt(key, spec, now_ms);
        try self.session.requestRedraw(self.window);
    }

    pub fn animationDemand(self: *const App, now_ms: u64, interval_ms: u32) animation.Demand {
        return self.animations.demand(now_ms, interval_ms);
    }

    /// GPU hosts call this after successful presentation; headless frames
    /// call it during publication because they have no later render pass.
    pub fn framePresented(self: *App, time_ms: u64) void {
        self.animations.framePresented(time_ms);
    }

    /// The single writer for this App's motion gate, and the only bridge
    /// target the host layer has. `reducedMotion` is the only reader, so the
    /// desktop preference and the animation registry can never hold two
    /// different answers for the same question.
    ///
    /// An in-flight channel is neither cancelled nor restarted. It snaps to
    /// the endpoint its spec author wrote, exactly one further frame is
    /// requested to paint that snap, and the registry then reports no
    /// animation demand again. The App's own display copy moves with the
    /// snap, so a host reading it before the redraw lands sees the endpoint
    /// too. Lowering the gate resumes live channels from their own clock; it
    /// never rewinds a parked one and never requests a frame for a value
    /// that did not move.
    pub fn setReducedMotion(self: *App, enabled: bool, now_ms: u64) !void {
        if (!self.session.hasWindow(self.window)) return error.UnknownWindow;
        if (self.animations.reduced_motion == enabled) return;
        self.animations.setReducedMotion(enabled, now_ms);
        if (enabled) {
            if (self.press_visual) |owner| {
                self.press_alpha = self.animations
                    .sample(.{ .owner = owner, .lane = 1 }, now_ms) orelse 0;
            }
            if (self.hover_visual) |owner| {
                self.hover_alpha = self.animations
                    .sample(.{ .owner = owner, .lane = 2 }, now_ms) orelse 0;
            }
        }
        try self.session.requestRedraw(self.window);
    }

    /// Whether decorative motion is suppressed. This is the running value;
    /// a host motion preference is only an input to it.
    pub fn reducedMotion(self: *const App) bool {
        return self.animations.reduced_motion;
    }

    /// A stable handle resolves only against this App's current committed tree.
    pub fn scrollHandle(self: *const App, widget_id: WidgetId) ?scroll_api.Handle {
        const target: scroll_api.Handle = .{ .window = self.window, .widget = widget_id };
        return if (self.scrollSnapshot(target) != null) target else null;
    }

    pub fn scrollSnapshot(self: *const App, target: scroll_api.Handle) ?scroll_api.Snapshot {
        if (!self.session.hasWindow(self.window)) return null;
        const tree = self.tree_ptr orelse return null;
        return scroll_api.resolve(tree, self.window, target);
    }

    fn scrollTree(self: *App) !*WidgetTree {
        if (!self.session.hasWindow(self.window)) return error.UnknownWindow;
        if (self.session.frame_window != null or self.session.draw_depth != 0 or
            self.session.update_depth != 0 or self.session.borrow_depth != 0 or
            self.session.release_depth != 0 or self.session.effect_queue.draining)
            return error.TransactionInProgress;
        return self.tree_ptr orelse error.RootNotMounted;
    }

    pub fn scrollTo(self: *App, target: scroll_api.Handle, offset: [2]f32) !bool {
        const changed = scroll_api.scrollTo(try self.scrollTree(), self.window, target, offset);
        if (changed) try self.session.requestRedraw(self.window);
        return changed;
    }

    pub fn scrollBy(self: *App, target: scroll_api.Handle, delta: [2]f32) !bool {
        const changed = scroll_api.scrollBy(try self.scrollTree(), self.window, target, delta);
        if (changed) try self.session.requestRedraw(self.window);
        return changed;
    }

    pub fn revealRect(
        self: *App,
        target: scroll_api.Handle,
        rect: widget.Rect,
        alignment: scroll_api.Alignment,
    ) !bool {
        const changed = scroll_api.revealRect(try self.scrollTree(), self.window, target, rect, alignment);
        if (changed) try self.session.requestRedraw(self.window);
        return changed;
    }

    pub fn setCounterSink(self: *App, counters: ?*perf_counters.Counters) void {
        self.counter_sink = CounterSink.init(counters);
    }

    fn sameComponent(a: Component, b: Component) bool {
        return a.ptr == b.ptr and a.vtable == b.vtable;
    }

    fn initGpuEntry(self: *App, entry: *ComponentEntry) !void {
        const endpoint = self.gpu_endpoint orelse return;
        if (entry.gpu_initialized) return;
        // A failing hook may already have created resources. Rollback owns them.
        entry.gpu_initialized = true;
        if (entry.component.vtable.init_gpu) |init_gpu| {
            try init_gpu(entry.component.ptr, endpoint);
        }
    }

    fn deinitGpuEntry(self: *App, entry: *ComponentEntry) void {
        if (!entry.gpu_initialized) return;
        if (self.gpu_endpoint) |endpoint| {
            if (entry.component.vtable.deinit_gpu) |deinit_gpu| {
                deinit_gpu(entry.component.ptr, endpoint);
            }
        }
        entry.gpu_initialized = false;
    }

    fn hasGpuRelease(entry: ComponentEntry) bool {
        return entry.gpu_initialized and entry.component.vtable.deinit_gpu != null;
    }

    fn reusedGpuMount(self: *const App, identity: ComponentId, staged: ComponentEntry) bool {
        const previous = self.identity_registry.map.get(identity) orelse return false;
        return previous.gpu_initialized and sameComponent(previous.component, staged.component);
    }

    /// Only mounts first initialized by this attempt belong to rollback.
    fn rollbackStagedGpu(self: *App, staged: *ComponentRegistry) void {
        const endpoint = self.gpu_endpoint orelse return;
        var needs_wait = false;
        var mounts = staged.map.iterator();
        while (mounts.next()) |mount| {
            if (self.reusedGpuMount(mount.key_ptr.*, mount.value_ptr.*)) continue;
            if (hasGpuRelease(mount.value_ptr.*)) needs_wait = true;
        }
        if (needs_wait) {
            endpoint.waitForRetirement() catch @panic("GPU retirement wait failed during rollback");
        }
        mounts = staged.map.iterator();
        while (mounts.next()) |mount| {
            if (self.reusedGpuMount(mount.key_ptr.*, mount.value_ptr.*)) continue;
            self.deinitGpuEntry(mount.value_ptr);
        }
    }

    /// Retire missing or replaced mounts only after all fallible frame work.
    fn retireOldGpu(self: *App, staged: *const ComponentRegistry) !void {
        const endpoint = self.gpu_endpoint orelse return;
        var needs_wait = false;
        var mounts = self.identity_registry.map.iterator();
        while (mounts.next()) |mount| {
            const next = staged.map.get(mount.key_ptr.*);
            if (next != null and sameComponent(mount.value_ptr.component, next.?.component)) continue;
            if (hasGpuRelease(mount.value_ptr.*)) needs_wait = true;
        }
        if (needs_wait) try endpoint.waitForRetirement();
        mounts = self.identity_registry.map.iterator();
        while (mounts.next()) |mount| {
            const next = staged.map.get(mount.key_ptr.*);
            if (next != null and sameComponent(mount.value_ptr.component, next.?.component)) continue;
            self.deinitGpuEntry(mount.value_ptr);
        }
    }

    /// Attach a persistent renderer endpoint. Entries mounted in the current
    /// frame are initialized before this call returns.
    pub fn attachGpu(self: *App, endpoint: *GpuEndpoint) !void {
        if (self.gpu_endpoint) |current| {
            if (current != endpoint) {
                self.detachGpu();
            }
        }
        self.gpu_endpoint = endpoint;
        errdefer self.detachGpu();

        var iterator = self.identity_registry.map.iterator();
        while (iterator.next()) |entry| {
            if (entry.value_ptr.last_seen_frame == self.frame_generation) {
                try self.initGpuEntry(entry.value_ptr);
            }
        }
    }

    /// Detach after one completion wait for the full mounted-resource batch.
    pub fn detachGpu(self: *App) void {
        const endpoint = self.gpu_endpoint orelse return;
        var needs_wait = false;
        var mounts = self.identity_registry.map.iterator();
        while (mounts.next()) |mount| {
            if (hasGpuRelease(mount.value_ptr.*)) needs_wait = true;
        }
        if (needs_wait) {
            endpoint.waitForRetirement() catch @panic("GPU retirement wait failed during detach");
        }
        mounts = self.identity_registry.map.iterator();
        while (mounts.next()) |mount| {
            self.deinitGpuEntry(mount.value_ptr);
        }
        self.gpu_endpoint = null;
    }

    pub fn deinit(self: *App) void {
        // A mounted frame names this App's trees; it must stop answering
        // before the arenas that hold them are released.
        if (self.overlay) |overlay_frame| overlay_frame.invalidate();
        self.overlay = null;
        self.detachGpu();
        self.text_input.clear();
        if (self.root_model) |*model| {
            self.session.releaseErased(model) catch @panic("App model release failed");
        }
        self.components.deinit(self.gpa);
        self.deferred_components.deinit(self.gpa);
        self.identity_registry.deinit();
        self.animations.deinit();
        self.widget_identities.deinit();
        self.layout_storage.deinit();
        self.arenas[0].deinit();
        self.arenas[1].deinit();
        self.session.unregisterApp(self.window);
        self.* = undefined;
    }

    /// Bind one caller-owned view. Keep it alive through App deinit and any
    /// readable snapshots, including snapshots retained after replacement.
    pub fn mountRoot(self: *App, comptime V: type, view: *V) !void {
        if (self.identity_registry.map.contains(.root)) return error.RootAlreadyMounted;
        try self.swapRoot(Component.make(V, view), null, null);
    }

    /// Retain the model independently of the caller's strong owner.
    pub fn mountModelRoot(
        self: *App,
        comptime M: type,
        comptime V: type,
        model: Model(M),
        view: *V,
    ) !void {
        if (self.identity_registry.map.contains(.root)) return error.RootAlreadyMounted;
        try self.swapModelRoot(M, V, model, view);
    }

    /// Replace the root atomically; a failed mount keeps the old input tree.
    /// A successful mount revokes old callbacks and starts fresh local state.
    pub fn replaceRoot(self: *App, comptime V: type, view: *V) !void {
        if (!self.identity_registry.map.contains(.root)) return error.RootNotMounted;
        try self.swapRoot(Component.make(V, view), null, null);
    }

    pub fn replaceModelRoot(
        self: *App,
        comptime M: type,
        comptime V: type,
        model: Model(M),
        view: *V,
    ) !void {
        if (!self.identity_registry.map.contains(.root)) return error.RootNotMounted;
        try self.swapModelRoot(M, V, model, view);
    }

    fn swapModelRoot(
        self: *App,
        comptime M: type,
        comptime V: type,
        model: Model(M),
        view: *V,
    ) !void {
        // A failed borrow check must not leave a retained ticket to roll back
        // while either the old or candidate model is still borrowed.
        if (self.root_model) |old| try self.session.canReleaseErased(old);
        var candidate = model;
        try self.session.canReleaseErased(candidate.erase());
        var retained = try self.session.retain(M, model);
        const weak = retained.weak().erase();
        try self.swapRoot(Component.makeModel(M, V, view), retained.erase(), weak);
    }

    pub fn dispatchRootFrame(self: *App, time_ms: u64) void {
        const root = self.identity_registry.map.get(.root) orelse return;
        if (root.component.vtable.on_frame) |on_frame| {
            on_frame(root.component.ptr, time_ms);
        }
    }

    /// True only when the mounted root has this concrete type and receiver.
    pub fn currentRootMatches(self: *const App, comptime T: type, root: *T) bool {
        const mounted = self.identity_registry.map.get(.root) orelse return false;
        return mounted.component.vtable.receiver_type == model_type.marker(T) and
            mounted.component.ptr == @as(*anyopaque, @ptrCast(root));
    }

    pub fn dispatchRootPrecisionKey(self: *App) bool {
        const root = self.identity_registry.map.get(.root) orelse return false;
        const on_precision_key = root.component.vtable.on_precision_key orelse return false;
        on_precision_key(root.component.ptr);
        return true;
    }

    /// All fallible work precedes publication. Old mounts retire as one GPU
    /// batch; failed preparation leaves the prior view and callbacks live.
    fn swapRoot(
        self: *App,
        component: Component,
        acquired_model: ?ErasedModel,
        weak: ?ErasedWeakModel,
    ) !void {
        var next_model = acquired_model;
        errdefer if (next_model) |*model| {
            self.session.releaseErased(model) catch @panic("App model rollback failed");
        };
        if (self.session.draw_depth != 0 or self.session.isFrameBuilding() or self.settling)
            return error.DrawMutationForbidden;
        if (acquired_model == null) {
            if (self.root_model) |old_model| try self.session.canReleaseErased(old_model);
        }
        const previous = self.identity_registry.map.get(ComponentId.root);
        var mounted_entries = self.identity_registry.map.iterator();
        while (mounted_entries.next()) |entry| {
            if (entry.value_ptr.component.ptr != component.ptr) continue;
            if (std.meta.eql(entry.key_ptr.*, ComponentId.root) and
                entry.value_ptr.component.vtable == component.vtable) continue;
            return error.ComponentAlreadyMounted;
        }
        try self.components.ensureTotalCapacity(self.gpa, 1);
        try self.identity_registry.map.ensureTotalCapacity(self.gpa, 1);
        const reuse = if (previous) |old|
            old.gpu_initialized and sameComponent(old.component, component)
        else
            false;
        var next_mount: ComponentEntry = .{
            .component = component,
            .last_seen_frame = self.frame_generation,
            .gpu_initialized = reuse,
        };
        errdefer if (!reuse and hasGpuRelease(next_mount)) {
            self.gpu_endpoint.?.waitForRetirement() catch
                @panic("GPU retirement wait failed during root rollback");
            self.deinitGpuEntry(&next_mount);
        };
        if (!reuse) try self.initGpuEntry(&next_mount);
        try self.widget_identities.beginFrame();
        errdefer self.widget_identities.abortFrame();

        // Replay the pending chord against its prior tree before old mounts
        // retire. A replay or retirement-wait failure leaves those mounts live.
        try self.flushShortcuts();

        if (self.gpu_endpoint) |endpoint| {
            var need_wait = false;
            var mounts = self.identity_registry.map.iterator();
            while (mounts.next()) |entry| {
                if (std.meta.eql(entry.key_ptr.*, ComponentId.root) and reuse) continue;
                if (hasGpuRelease(entry.value_ptr.*)) need_wait = true;
            }
            if (need_wait) try endpoint.waitForRetirement();
            mounts = self.identity_registry.map.iterator();
            while (mounts.next()) |entry| {
                if (std.meta.eql(entry.key_ptr.*, ComponentId.root) and reuse) continue;
                self.deinitGpuEntry(entry.value_ptr);
            }
        }

        self.focus_manager.reset(self.focusObserver());
        self.components.clearRetainingCapacity();
        self.components.putAssumeCapacity(@fromBackingInt(@intCast(1)), component);
        self.identity_registry.map.clearRetainingCapacity();
        self.identity_registry.map.putAssumeCapacity(ComponentId.root, next_mount);
        self.widget_identities.commitFrame(); // Retire old keys and bump recycled generations.
        self.animations.clear();
        // Every fallible step is behind us and the old mounts have retired as
        // one GPU batch. A FAILED replacement returned above with the prior
        // view, its mounts and its callbacks untouched. The replacement
        // retires the tree the mounted frame placed into, so the frame stops
        // answering at the non-fallible cutover.
        if (self.overlay) |overlay_frame| overlay_frame.invalidate();
        self.tree_ptr = null; // Prior snapshots stay readable, but cannot dispatch.
        self.state_prev = null;
        self.mouse_pos = null;
        self.pressed = null;
        self.press_alpha = 0;
        self.hover_alpha = 0;
        self.press_visual = null;
        self.hover_visual = null;
        self.last_time_ms = 0;
        const old_model = self.root_model;
        self.root_model = next_model;
        self.root_model_weak = weak;
        next_model = null;
        self.session.clearWindowDependencies(self.window) catch
            @panic("published root dependency cleanup failed");
        self.session.requestRedraw(self.window) catch
            @panic("published root redraw request failed");
        if (old_model) |model| {
            var owned = model;
            self.session.releaseErased(&owned) catch @panic("App old model release failed");
        }
    }

    /// Resolve a keyed handle in the committed tree, or in the candidate tree
    /// while this App is running its semantic annotation hook.
    pub fn widgetIdForKey(self: *const App, scope: ComponentId, key: ComponentKey) ?WidgetId {
        const tree = self.semantic_tree orelse self.tree_ptr orelse return null;
        const id = (if (self.semantic_tree != null)
            self.widget_identities.lookupFrameWidget(scope, key)
        else
            self.widget_identities.lookupWidget(scope, key)) orelse return null;
        if (tree.frameNode(id) == null) return null;
        return id;
    }

    /// Build and publish one frame. The root owns dense component node 1.
    /// A returned tree stays valid through the next frame attempt; prev_tree
    /// stays valid until the next attempt. Frame-local node ids may change
    /// with draw order; keyed WidgetIds resolve within each tree separately.
    /// The caller owns and frees optional GPA-allocated JSON.
    ///
    /// Input events dispatch only against the last committed tree. A frame
    /// event builds a new tree and publishes it only after all work succeeds.
    pub fn handle(self: *App, ev: Event) !?FrameOutput {
        self.last_input_default_prevented = false;
        switch (ev) {
            .frame => |f| {
                try self.tickShortcuts();
                return try self.presentAndSettle(f.tick, f.time_ms, self.surface, null);
            },
            .resize => |r| {
                self.surface = .{ .width = r.width, .height = r.height };
                self.text_input.invalidateGeometry();
            },
            .mouse_wheel => |wheel| {
                const tree = self.tree_ptr orelse return null;
                const hit = self.hitNode(tree, .{ wheel.x, wheel.y }) orelse return null;
                _ = self.routeTo(tree, hit, &ev);
            },
            .mouse_move => |m| {
                self.mouse_pos = .{ m.x, m.y };
                const tree = self.tree_ptr orelse return null;
                const captured = self.focus_manager.captured(
                    tree,
                    .{ .mouse = .left },
                    self.focusObserver(),
                );
                if (captured) |id| {
                    if (tree.frameNode(id)) |node| {
                        // The tree's own border box IS the placed box, so the
                        // pointer maps against where the rail is drawn.
                        _ = event.sliderSet(
                            tree,
                            node,
                            m.x,
                            widget.visualBorderRect(tree, node),
                        );
                        _ = self.routeTo(tree, node, &ev);
                    }
                } else if (self.hitNode(tree, .{ m.x, m.y })) |hit| {
                    _ = self.routeTo(tree, hit, &ev);
                }
            },
            .mouse_leave => {
                // Leaving clears hover and never releases a pointer captured
                // in-window, so the consumer that still owns that capture is
                // reached by the move that follows, not by this event. The
                // widget the pointer was over is told before the position
                // that named it is gone.
                self.routeToPointerOwner(&ev);
                self.mouse_pos = null;
            },
            .window_focus_lost => {
                // The pointer owner hears the window lost focus while the
                // last position can still name it; the reset that follows
                // revokes every capture and blurs the keyboard, so each
                // captured owner also gets its own capture_lost.
                self.routeToPointerOwner(&ev);
                try self.flushShortcuts();
                self.focus_manager.reset(self.focusObserver());
                self.mouse_pos = null;
                self.pressed = null;
            },
            .mouse_down => |down| {
                const tree = self.tree_ptr orelse return null;
                const hit = self.hitNode(tree, .{ down.x, down.y }) orelse return null;
                const routed = self.routeTo(tree, hit, &ev) orelse return null;
                if (routed.default_prevented or self.tree_ptr != tree) return null;
                const target = self.hitStableNode(tree, .{ down.x, down.y }) orelse return null;
                if (!try self.focus_manager.press(
                    tree,
                    .{ .mouse = down.button },
                    target,
                )) return null;
                if (down.button == .left) {
                    if (self.focus_manager.current == null or
                        !self.focus_manager.current.?.eql(target)) try self.flushShortcuts();
                    _ = self.focus_manager.set(tree, target, self.focusObserver());
                    if (isButton(tree, target)) self.pressed = target;
                    if (tree.frameNode(target)) |node| {
                        _ = event.sliderSet(
                            tree,
                            node,
                            down.x,
                            widget.visualBorderRect(tree, node),
                        );
                    }
                }
            },
            .mouse_up => |up| {
                const tree = self.tree_ptr orelse return null;
                const hit = self.hitNode(tree, .{ up.x, up.y });
                const captured = self.focus_manager.captured(
                    tree,
                    .{ .mouse = up.button },
                    self.focusObserver(),
                );
                var prevented = false;
                if (captured) |id| {
                    if (tree.frameNode(id)) |node| {
                        const routed = self.routeTo(tree, node, &ev);
                        prevented = if (routed) |result| result.default_prevented else false;
                    }
                } else if (hit) |node| {
                    const routed = self.routeTo(tree, node, &ev);
                    prevented = if (routed) |result| result.default_prevented else false;
                }
                if (self.tree_ptr != tree) return null;
                const release = self.focus_manager.release(
                    tree,
                    .{ .mouse = up.button },
                    self.hitStableNode(tree, .{ up.x, up.y }),
                    self.focusObserver(),
                );
                if (up.button == .left) self.pressed = null;
                if (release.activate and !prevented) {
                    self.activateFrom(tree, release.target.?, .pointer, up.click_count);
                }
            },
            .mouse_cancel => |cancelled| {
                const tree = self.tree_ptr orelse return null;
                if (self.focus_manager.captured(
                    tree,
                    .{ .mouse = cancelled.button },
                    self.focusObserver(),
                )) |id| {
                    if (tree.frameNode(id)) |node| _ = self.routeTo(tree, node, &ev);
                }
                self.cancellation_routed = true;
                defer self.cancellation_routed = false;
                self.focus_manager.cancel(.{ .mouse = cancelled.button }, self.focusObserver());
                if (cancelled.button == .left) self.pressed = null;
            },
            .touch_start => |touch| {
                const tree = self.tree_ptr orelse return null;
                const hit = self.hitNode(tree, .{ touch.x, touch.y }) orelse return null;
                const routed = self.routeTo(tree, hit, &ev) orelse return null;
                if (routed.default_prevented or self.tree_ptr != tree) return null;
                const target = self.hitStableNode(tree, .{ touch.x, touch.y }) orelse return null;
                _ = try self.focus_manager.press(tree, .{ .touch = touch.id }, target);
            },
            .touch_move, .touch_end, .touch_cancel => {
                const touch = switch (ev) {
                    .touch_move => |value| value,
                    .touch_end => |value| value,
                    .touch_cancel => |value| value,
                    else => unreachable,
                };
                const tree = self.tree_ptr orelse return null;
                const pointer: focus.PointerId = .{ .touch = touch.id };
                const target = self.focus_manager.captured(tree, pointer, self.focusObserver());
                var prevented = false;
                if (target) |id| {
                    if (tree.frameNode(id)) |node| {
                        const routed = self.routeTo(tree, node, &ev);
                        prevented = if (routed) |result| result.default_prevented else false;
                    }
                }
                if (self.tree_ptr != tree) return null;
                switch (ev) {
                    .touch_end => {
                        const release = self.focus_manager.release(
                            tree,
                            pointer,
                            self.hitStableNode(tree, .{ touch.x, touch.y }),
                            self.focusObserver(),
                        );
                        if (release.activate and !prevented) {
                            self.activateFrom(tree, release.target.?, .pointer, 1);
                        }
                    },
                    .touch_cancel => {
                        self.cancellation_routed = true;
                        defer self.cancellation_routed = false;
                        self.focus_manager.cancel(pointer, self.focusObserver());
                    },
                    else => {},
                }
            },
            .key_down => |key| {
                const tree = self.tree_ptr orelse return null;
                const routed = self.routeFocused(tree, &ev);
                if (self.tree_ptr != tree) return null;
                const prevented = routed != null and routed.?.default_prevented;
                if (self.shortcuts) |bindings| {
                    var dispatch: ShortcutDispatch = .{ .app = self, .tree = tree };
                    const decision = bindings.map.keyDown(
                        key,
                        self.shortcutScope(),
                        prevented,
                        dispatch.sink(),
                    );
                    try dispatch.finish();
                    if (prevented or decision == .waiting or decision == .handled)
                        self.last_input_default_prevented = true;
                    return null;
                }
                if (prevented) return null;
                try self.defaultShortcutInput(tree, ev);
            },
            .key_up, .text_input, .composition => {
                const tree = self.tree_ptr orelse return null;
                const routed = self.routeFocused(tree, &ev);
                if (self.tree_ptr != tree) return null;
                const prevented = routed != null and routed.?.default_prevented;
                if (self.shortcuts) |bindings| {
                    var dispatch: ShortcutDispatch = .{ .app = self, .tree = tree };
                    switch (ev) {
                        .key_up => |key| bindings.map.keyUp(
                            key,
                            self.shortcutFocusToken(),
                            dispatch.sink(),
                        ),
                        .text_input => |input_event| bindings.map.textInput(
                            input_event.text,
                            self.shortcutFocusToken(),
                            prevented,
                            dispatch.sink(),
                        ),
                        .composition => {
                            if (!prevented and try self.text_input.handle(&ev) != .ignored)
                                self.last_input_default_prevented = true;
                            return null;
                        },
                        else => unreachable,
                    }
                    try dispatch.finish();
                    if (prevented) self.last_input_default_prevented = true;
                    return null;
                }
                if (prevented) return null;
                if (try self.text_input.handle(&ev) != .ignored)
                    self.last_input_default_prevented = true;
            },
            .activate => |activation| {
                const tree = self.tree_ptr orelse return null;
                self.activateFrom(
                    tree,
                    activation.target_id,
                    activation.source,
                    activation.click_count,
                );
            },
            .focus_in, .focus_out, .capture_lost => {
                const tree = self.tree_ptr orelse return null;
                const target_id = switch (ev) {
                    .focus_in => |change| change.target_id,
                    .focus_out => |change| change.target_id,
                    .capture_lost => |change| change.target_id,
                    else => unreachable,
                };
                const node = tree.frameNode(target_id) orelse return null;
                _ = self.routeTo(tree, node, &ev);
            },
        }
        return null;
    }

    fn routeFocused(self: *App, tree: *const WidgetTree, ev: *const Event) ?event.DispatchContext {
        if (self.focus_manager.current) |id| {
            if (tree.frameNode(id)) |node| return self.routeTo(tree, node, ev);
        }
        if (tree.nodes.items.len == 0) return null;
        return self.routeTo(tree, tree.nodes.items[tree.nodes.items.len - 1].id, ev);
    }

    /// The node the pointer was last over. `mouse_leave` and
    /// `window_focus_lost` carry no coordinates, so the consumer they
    /// affect is the one the last committed position still names. An
    /// uncommitted tree or an absent position routes nothing, and the
    /// caller's own reset still runs.
    fn routeToPointerOwner(self: *App, ev: *const Event) void {
        const tree = self.tree_ptr orelse return;
        const point = self.mouse_pos orelse return;
        const node = self.hitNode(tree, point) orelse return;
        _ = self.routeTo(tree, node, ev);
    }

    fn routeTo(
        self: *App,
        tree: *const WidgetTree,
        node: FrameNodeId,
        ev: *const Event,
    ) ?event.DispatchContext {
        return self.routeWithComponents(tree, &self.components, node, ev);
    }

    fn routeWithComponents(
        self: *App,
        tree: *const WidgetTree,
        components: *const ComponentMap,
        node: FrameNodeId,
        ev: *const Event,
    ) ?event.DispatchContext {
        const previous_tree = self.routing_tree;
        const previous_components = self.routing_components;
        const previous_owner = self.routing_owner;
        const previous_phase = self.routing_phase;
        self.routing_tree = tree;
        self.routing_components = components;
        self.routing_owner = null;
        self.routing_phase = null;
        defer {
            self.routing_tree = previous_tree;
            self.routing_components = previous_components;
            self.routing_owner = previous_owner;
            self.routing_phase = previous_phase;
        }
        const result = event.dispatch(tree, node, ev, .{
            .user = self,
            .on_event = onRoutedEvent,
            .on_default = onRoutedDefault,
        });
        if (result) |routed| {
            if (routed.default_prevented or routed.default_target != null) {
                self.last_input_default_prevented = true;
            }
        }
        return result;
    }

    fn onRoutedEvent(user: *anyopaque, context: *event.DispatchContext) void {
        const self: *App = @ptrCast(@alignCast(user));
        const tree = self.routing_tree orelse self.tree_ptr orelse return;
        const node = tree.nodeConst(context.current_target) orelse return;
        // A component owns every node it drew, so one event reaches it once
        // per owned node on the path. Those nodes form a single run along a
        // root-to-target path, so the first of the run is the outermost node
        // during capture and the innermost one during bubble: the node whose
        // subtree the consumer is responsible for.
        if (self.routing_phase != context.phase) {
            self.routing_phase = context.phase;
            self.routing_owner = null;
        }
        if (self.routing_owner) |owner| {
            if (owner == node.owner) return;
        }
        const components = self.routing_components orelse &self.components;
        const component = components.get(node.owner) orelse return;
        const callback = component.vtable.on_routed_event orelse return;
        self.routing_owner = node.owner;
        callback(component.ptr, context);
    }

    fn onRoutedDefault(user: *anyopaque, context: *event.DispatchContext) void {
        const self: *App = @ptrCast(@alignCast(user));
        const action = switch (context.event.*) {
            .activate => |value| value,
            else => return,
        };
        const tree = self.tree_ptr orelse return;
        _ = event.activate(tree, action.target_id, &self.components);
    }

    /// The observer this App hands to every focus change it makes, and the one
    /// a caller passes when it moves focus itself: a focus scope, a
    /// programmatic move through `focus_manager`. The App then routes
    /// focus_out/focus_in, reconciles its text endpoint and reports the change
    /// to `focus_observer` exactly as it does for its own input. A null
    /// observer writes the new value and reports nothing, which is what a
    /// caller that only wants the value asks for.
    pub fn focusObserver(self: *App) focus.Observer {
        return .{
            .user = self,
            .on_focus = onFocusChanged,
            .on_cancel = onCaptureCancelled,
        };
    }

    /// A focus change runs in four steps: the endpoint that owned the
    /// keyboard retires, the widget that lost it is told, the widget that
    /// gained it is told, and the observer hears about it. They are separate
    /// functions because a publication holding a chord runs everything but
    /// the focus_out late, once that input reached the endpoint it retires.
    fn onFocusChanged(user: *anyopaque, change: focus.Change) void {
        const self: *App = @ptrCast(@alignCast(user));
        self.text_input.reconcile(change.current);
        self.routeFocusOut(change);
        if (self.routeFocusIn(change)) self.reportFocusChange(change);
    }

    /// Tell the widget that lost the keyboard, against the tree and dense
    /// owners that still hold it. A deferred change names the publication it
    /// retired; every other change names the committed pair.
    fn routeFocusOutIn(
        self: *App,
        tree: *const WidgetTree,
        components: *const ComponentMap,
        change: focus.Change,
    ) void {
        const previous = change.previous orelse return;
        const node = tree.frameNode(previous) orelse return;
        const ev: Event = .{ .focus_out = .{
            .target_id = previous,
            .related = change.current,
        } };
        _ = self.routeWithComponents(tree, components, node, &ev);
    }

    fn routeFocusOut(self: *App, change: focus.Change) void {
        const tree = self.tree_ptr orelse return;
        self.routeFocusOutIn(tree, &self.components, change);
    }

    /// Tell the widget that gained the keyboard. False means the change
    /// named a new focus that no live tree can route, which stops the
    /// observer report as it did when this ran as one function.
    fn routeFocusIn(self: *App, change: focus.Change) bool {
        const current = change.current orelse return true;
        const tree = self.publishing_tree orelse self.tree_ptr orelse return false;
        const node = tree.frameNode(current) orelse return true;
        const ev: Event = .{ .focus_in = .{
            .target_id = current,
            .related = change.previous,
        } };
        if (self.publishing_components) |components| {
            _ = self.routeWithComponents(tree, components, node, &ev);
        } else {
            _ = self.routeTo(tree, node, &ev);
        }
        return true;
    }

    /// A publication defers the observer report with the rest of the change;
    /// everything else reports as soon as it happens.
    fn reportFocusChange(self: *App, change: focus.Change) void {
        if (self.publishing_tree != null) {
            self.pending_focus_change = change;
        } else if (self.focus_observer) |observer| {
            if (observer.on_focus) |notify| notify(observer.user, change);
        }
    }

    fn onCaptureCancelled(user: *anyopaque, cancellation: focus.Cancellation) void {
        const self: *App = @ptrCast(@alignCast(user));
        if (!self.cancellation_routed) if (self.tree_ptr) |tree| {
            if (tree.frameNode(cancellation.target)) |node| {
                const ev: Event = .{ .capture_lost = .{
                    .target_id = cancellation.target,
                    .pointer = cancellation.pointer,
                } };
                _ = self.routeTo(tree, node, &ev);
            }
        };
        if (self.publishing_tree != null) {
            const slot = self.pending_cancellation_count;
            std.debug.assert(slot < self.pending_cancellations.len);
            self.pending_cancellations[slot] = cancellation;
            self.pending_cancellation_count += 1;
        } else if (self.focus_observer) |observer| {
            if (observer.on_cancel) |notify| notify(observer.user, cancellation);
        }
    }

    fn flushInputNotifications(self: *App) void {
        const cancellations = self.pending_cancellations[0..self.pending_cancellation_count];
        self.pending_cancellation_count = 0;
        const change = self.pending_focus_change;
        self.pending_focus_change = null;
        const observer = self.focus_observer orelse return;
        if (observer.on_cancel) |notify| {
            for (cancellations) |cancellation| notify(observer.user, cancellation);
        }
        if (change) |focus_change| {
            if (observer.on_focus) |notify| notify(observer.user, focus_change);
        }
    }

    fn activateFrom(
        self: *App,
        tree: *const WidgetTree,
        id: WidgetId,
        source: event.ActivationSource,
        click_count: u8,
    ) void {
        if (self.tree_ptr != tree) return;
        const node = tree.frameNode(id) orelse return;
        const action: Event = .{ .activate = .{
            .target_id = id,
            .source = source,
            .click_count = click_count,
        } };
        _ = self.routeTo(tree, node, &action);
    }

    /// Key defaults run only after focused component routing.
    fn handleKey(self: *App, tree: *const WidgetTree, key: KeyEvent) void {
        switch (key.key) {
            .tab => {
                _ = self.focus_manager.step(
                    tree,
                    if (key.shifted()) .backward else .forward,
                    null,
                    self.focusObserver(),
                );
            },
            .enter, .space => {
                if (key.repeat) return;
                const id = self.focus_manager.current orelse return;
                const dense_id = tree.frameNode(id) orelse return;
                if (!input.isEnabled(tree, dense_id)) return;
                if (key.key == .space) {
                    if (tree.nodeConst(dense_id)) |node| {
                        switch (node.kind) {
                            .slider => |slider| {
                                slider.value.* = slider.max;
                                return;
                            },
                            else => {},
                        }
                    }
                }
                self.activateFrom(tree, id, .keyboard, 1);
            },
            .left, .right, .up, .down, .home, .end => {
                const focused_id = self.focus_manager.current orelse return;
                const dense_id = tree.frameNode(focused_id) orelse return;
                if (!input.isEnabled(tree, dense_id)) return;
                const node = tree.nodeConst(dense_id) orelse return;
                switch (node.kind) {
                    .radio => switch (key.key) {
                        .left, .up => self.focusRadio(tree, node, -1),
                        .right, .down => self.focusRadio(tree, node, 1),
                        else => {},
                    },
                    .slider => |slider| {
                        const span = slider.max - slider.min;
                        const step: f32 = switch (key.key) {
                            .left, .down => -span * 0.05,
                            .right, .up => span * 0.05,
                            .home => -span,
                            .end => span,
                            else => unreachable,
                        };
                        slider.value.* = std.math.clamp(
                            slider.value.* + step,
                            slider.min,
                            slider.max,
                        );
                    },
                    else => {},
                }
            },
            .escape => self.focus_manager.blur(self.focusObserver()),
            .unidentified => {},
        }
    }

    /// Move to the adjacent radio option in the same group and select it.
    /// The group uses the same parent and selection pointer.
    fn focusRadio(
        self: *App,
        tree: *const WidgetTree,
        focused_node: *const WidgetNode,
        dir: i32,
    ) void {
        const radio = switch (focused_node.kind) {
            .radio => |value| value,
            else => return,
        };
        var sibling_count: usize = 0;
        var focused_index: ?usize = null;
        for (tree.nodes.items) |*sibling| {
            if (!isRadioSibling(tree, sibling, focused_node.parent, radio.selected)) continue;
            if (sibling.id == focused_node.id) focused_index = sibling_count;
            sibling_count += 1;
        }
        if (sibling_count == 0) return;
        var target_index = focused_index orelse return;
        if (dir > 0) {
            target_index += 1;
            if (target_index == sibling_count) target_index = 0;
        } else {
            target_index = if (target_index == 0) sibling_count - 1 else target_index - 1;
        }

        var sibling_index: usize = 0;
        for (tree.nodes.items) |*sibling| {
            if (!isRadioSibling(tree, sibling, focused_node.parent, radio.selected)) continue;
            if (sibling_index == target_index) {
                const target = sibling.widget_id orelse return;
                _ = self.focus_manager.set(tree, target, self.focusObserver());
                self.activateFrom(tree, target, .keyboard, 1);
                return;
            }
            sibling_index += 1;
        }
    }

    fn isRadioSibling(tree: *const WidgetTree, node: *const WidgetNode, parent: FrameNodeId, selected: *?u32) bool {
        if (node.parent != parent) return false;
        if (focus.defaultDescribe(tree, node) == null) return false;
        return switch (node.kind) {
            .radio => |radio| radio.selected == selected,
            else => false,
        };
    }

    fn isButton(tree: *const WidgetTree, id: WidgetId) bool {
        const dense_id = tree.frameNode(id) orelse return false;
        const node = tree.nodeConst(dense_id) orelse return false;
        return node.kind == .button and input.isEnabled(tree, dense_id);
    }

    /// Present one frame: the classic frame() entry (tests, one-shot shots)
    /// — the surface is passed explicitly and time starts at 0. The driver
    /// entry is handle(.frame), which uses the driver's surface + clock.
    pub fn frame(self: *App, frame_number: u32, surface: Size) !FrameOutput {
        return self.presentAndSettle(frame_number, 0, surface, null);
    }

    /// Present a driver-timed graphical frame after its Surface frame began.
    /// The caller owns Surface begin/end; App builds and lays out before
    /// dispatching component GPU hooks against `gpu_frame`.
    pub fn frameWithGpuAtTime(
        self: *App,
        frame_number: u32,
        time_ms: u64,
        surface: Size,
        gpu_frame: *GpuFrame,
    ) !FrameOutput {
        const endpoint = self.gpu_endpoint orelse return error.GpuEndpointNotAttached;
        if (gpu_frame.endpoint != endpoint) return error.GpuFrameEndpointMismatch;
        return self.presentAndSettle(frame_number, time_ms, surface, gpu_frame);
    }

    fn dispatchGpuFrame(
        self: *App,
        staged: *const ComponentRegistry,
        gpu_frame: *GpuFrame,
    ) !void {
        const endpoint = self.gpu_endpoint orelse return error.GpuEndpointNotAttached;
        if (gpu_frame.endpoint != endpoint) return error.GpuFrameEndpointMismatch;
        var iterator = staged.map.iterator();
        while (iterator.next()) |entry| {
            if (!entry.value_ptr.gpu_initialized) continue;
            if (entry.value_ptr.component.vtable.frame_gpu) |frame_gpu| {
                try frame_gpu(entry.value_ptr.component.ptr, gpu_frame);
            }
        }
    }

    fn present(
        self: *App,
        frame_number: u32,
        time_ms: u64,
        surface: Size,
        gpu_frame: ?*GpuFrame,
    ) !FrameOutput {
        const semantic_publication = self.semantic_publication;
        errdefer if (semantic_publication) |publication| publication.publisher.abort();
        // Even validation errors must close an already begun host recording.
        errdefer if (gpu_frame) |active| {
            active.cancelRecording() catch
                @panic("GPU recording cancellation failed during frame validation");
        };
        // Settling owns the tree the deferred focus_out must name, so no frame
        // may start until it finishes.
        if (self.settling) return error.FrameInProgress;
        const root_component = self.components.get(@fromBackingInt(@intCast(1))) orelse
            return error.RootNotMounted;
        try layout.validateAvailable(surface);
        const generation = std.math.add(u64, self.frame_generation, 1) catch
            return error.FrameGenerationExhausted;
        try self.session.beginFrame(self.window);
        var published = false;
        defer self.session.endFrame(self.window, published);

        const build_idx: u32 = 1 - self.current;
        {
            const zone = tracy.Zone.begin(.{ .name = "arenaReset", .src = @src() });
            defer zone.end();
            _ = self.arenas[build_idx].reset(.retain_capacity);
        }
        const arena_alloc = self.arenas[build_idx].allocator();
        var staged_components: std.AutoHashMapUnmanaged(FrameNodeId, Component) = .empty;
        var staged_mounts = ComponentRegistry.init(arena_alloc);
        var scroll_before_layout: std.AutoHashMapUnmanaged(*ScrollState, ScrollState) = .empty;
        try self.widget_identities.beginFrame();
        errdefer self.widget_identities.abortFrame();
        errdefer {
            var entries = scroll_before_layout.iterator();
            while (entries.next()) |entry| {
                const state = entry.key_ptr.*;
                state.* = entry.value_ptr.*;
            }
        }
        errdefer {
            // A pending command buffer may still name staged GPU resources.
            // Discard it before rollback deinitializes those resources.
            if (gpu_frame) |active| {
                active.cancelRecording() catch
                    @panic("GPU recording cancellation failed during frame rollback");
            }
            self.rollbackStagedGpu(&staged_mounts);
        }

        const tree = try arena_alloc.create(WidgetTree);
        tree.* = WidgetTree.init(arena_alloc);
        tree.setCounterSink(self.counter_sink.pointer());
        tree.next_id = 2; // Dense owner 1 belongs to the root component.
        const state_dir = try arena_alloc.create(StateDir);
        state_dir.* = .empty;

        try staged_components.put(arena_alloc, @fromBackingInt(@intCast(1)), root_component);
        const old_root = self.identity_registry.map.get(ComponentId.root) orelse
            return error.RootNotMounted;
        try staged_mounts.map.put(arena_alloc, ComponentId.root, .{
            .component = root_component,
            .last_seen_frame = generation,
            .gpu_initialized = old_root.gpu_initialized and
                sameComponent(old_root.component, root_component),
        });
        try self.initGpuEntry(staged_mounts.map.getPtr(ComponentId.root).?);

        var ctx: DrawCtx = .{
            .tree = tree,
            .arena = arena_alloc,
            .surface = surface,
            .frame_info = .{
                .tick = frame_number,
                .time_ms = time_ms,
                .generation = generation,
                .surface = surface,
            },
            .context = .{
                .session = self.session,
                .window = self.window,
                .root_model = self.root_model_weak,
            },
            .component_id = @fromBackingInt(@intCast(1)),
            .component_identity = ComponentId.root,
            .frame_generation = generation,
            .state_prev = self.state_prev,
            .state_cur = state_dir,
            .registry = .{ .map = &staged_components, .gpa = arena_alloc },
            .widget_identities = &self.widget_identities,
            .animations = &self.animations,
            .identity_map = &staged_mounts,
            .committed_identity_map = &self.identity_registry,
            .scroll_before_layout = &scroll_before_layout,
            .gpu_endpoint = self.gpu_endpoint,
            .overlay = self.overlay,
        };
        {
            self.session.beginDraw();
            defer self.session.endDraw();
            {
                const zone = tracy.Zone.begin(.{ .name = "appDraw", .src = @src() });
                // Placements are per frame: the draw that follows registers
                // this frame's popups, and a frame that draws none resolves
                // nothing.
                if (self.overlay) |overlay_frame| overlay_frame.beginFrame();
                defer zone.end();
                try root_component.vtable.draw(root_component.ptr, &ctx);
            }
            // Layout writes shared state before JSON and registry publication can fail.
            for (tree.nodes.items) |node| {
                if (node.scroll) |scroll| {
                    const entry = try scroll_before_layout.getOrPut(arena_alloc, scroll.state);
                    if (!entry.found_existing) entry.value_ptr.* = scroll.state.*;
                }
            }
            {
                const zone = tracy.Zone.begin(.{ .name = "layoutTree", .src = @src() });
                defer zone.end();
                try element.prepareLayout(&ctx, .{
                    .allocator = arena_alloc,
                    .available = surface,
                    .measure = self.measure,
                    .storage = &self.layout_storage,
                });
            }
            // Placement resolves against this frame's laid-out geometry and
            // BEFORE any custom element prepaint, paint or semantic hook, so
            // every hook and every later stage sees the box the consumer's
            // content will actually be drawn in. A frame that fails to
            // resolve fails this publication: the committed tree, its routing
            // and its bands stay exactly as they were. The bands themselves
            // resolve after the element hooks, below.
            if (self.overlay) |overlay_frame| {
                try overlay_frame.stage(tree, .{
                    .x = 0,
                    .y = 0,
                    .w = surface.width,
                    .h = surface.height,
                });
            }
            {
                const zone = tracy.Zone.begin(.{ .name = "elementPaint", .src = @src() });
                defer zone.end();
                try element.finishFrame(&ctx);
            }
            // Paint bands resolve AFTER every element hook — a custom
            // record's own layer bump is part of the maximum a band has to
            // clear — and BEFORE any GPU record, because the scene reads the
            // bands while it records. An App with no overlay still validates
            // those bumps here, so an overflowing layer fails publication on
            // both paths instead of only while a popup happens to be mounted.
            if (self.overlay) |overlay_frame| {
                try overlay_frame.finalizePaintOrder(tree);
            } else {
                _ = try widget.maximumPaintLayer(tree);
            }
        }
        if (gpu_frame) |active_gpu_frame| {
            const zone = tracy.Zone.begin(.{ .name = "gpuComponentDispatch", .src = @src() });
            defer zone.end();
            try self.dispatchGpuFrame(&staged_mounts, active_gpu_frame);
        }
        if (semantic_publication) |publication| {
            self.semantic_tree = tree;
            defer self.semantic_tree = null;
            try publication.publisher.stage(.{
                .tree = tree,
                .focus = self.focus_manager.current,
                .generation = generation,
                .surface = surface,
                .window_name = publication.window_name,
                .annotator = publication.annotator,
            });
        }

        // Compute display values without mutating input state before publication.
        var next_pressed = self.pressed;
        if (next_pressed) |id| {
            if (!isButton(tree, id)) next_pressed = null;
        }
        const hover: ?WidgetId = if (self.mouse_pos) |pos|
            self.hitStableNode(tree, pos)
        else
            null;
        const transition_time = if (self.frame_generation == 0)
            time_ms
        else
            @min(self.last_time_ms, time_ms);
        // Transition start validates its end time. Do that before old GPU
        // mounts retire, or an extreme clock value could abort publication.
        if (next_pressed != null or self.press_visual != null) {
            _ = std.math.add(u64, transition_time, 800) catch
                return error.AnimationTimeOverflow;
        }
        if (hover != null or self.hover_visual != null) {
            _ = std.math.add(u64, transition_time, 1440) catch
                return error.AnimationTimeOverflow;
        }
        // At most the previous/new hover and press keys can be introduced
        // this frame. Reserve before old GPU mounts can be retired.
        if (next_pressed != null or hover != null or
            self.press_visual != null or self.hover_visual != null)
        {
            try self.animations.timelines.ensureUnusedCapacity(self.gpa, 4);
            try self.animations.indexes.ensureUnusedCapacity(self.gpa, 4);
        }

        const json: ?[]const u8 = if (self.serialize_json) blk: {
            const zone = tracy.Zone.begin(.{ .name = "treeToJson", .src = @src() });
            defer zone.end();
            break :blk try headless.treeToJson(self.gpa, tree);
        } else null;
        errdefer if (json) |bytes| self.gpa.free(bytes);

        // Capacity is the last fallible allocation before retiring old GPU mounts.
        try self.components.ensureTotalCapacity(self.gpa, staged_components.count());
        try self.identity_registry.map.ensureTotalCapacity(
            self.gpa,
            staged_mounts.map.count(),
        );
        // A publication that defers a focus change routes that change's
        // focus_out against the dense owners it replaces, so their map is
        // reserved here and copied without a later allocation. No input can
        // arrive inside a frame, so a pending deadline at this point is the
        // same one the publication captures, or none at all.
        if (self.shortcuts != null and self.shortcuts.?.map.nextDeadline() != null) {
            try self.deferred_components.ensureTotalCapacity(self.gpa, self.components.count());
        }
        try self.retireOldGpu(&staged_mounts);
        var press_visual = next_pressed orelse self.press_visual;
        if (press_visual) |id| {
            if (tree.frameNode(id) == null) press_visual = null;
        }
        if (self.press_visual) |previous| {
            if (next_pressed == null or !previous.eql(next_pressed.?)) {
                try self.animations.transition(.{ .owner = previous, .lane = 1 }, .{
                    .from_if_absent = self.press_alpha,
                    .to = 0,
                    .duration_ms = 800,
                    .easing = .{ .exponential = 8 },
                    .now_ms = transition_time,
                });
            }
        }
        if (next_pressed) |id| {
            try self.animations.transition(.{ .owner = id, .lane = 1 }, .{
                .from_if_absent = 0,
                .to = 1,
                .duration_ms = 800,
                .easing = .{ .exponential = 8 },
                .now_ms = transition_time,
            });
        }
        const next_press_alpha = if (press_visual) |id|
            self.animations.sample(.{ .owner = id, .lane = 1 }, time_ms) orelse 0
        else
            0;
        if (next_press_alpha == 0 and next_pressed == null) press_visual = null;

        var hover_visual = hover orelse self.hover_visual;
        if (hover_visual) |id| {
            if (tree.frameNode(id) == null) hover_visual = null;
        }
        if (self.hover_visual) |previous| {
            if (hover == null or !previous.eql(hover.?)) {
                try self.animations.transition(.{ .owner = previous, .lane = 2 }, .{
                    .from_if_absent = self.hover_alpha,
                    .to = 0,
                    .duration_ms = 1440,
                    .easing = .{ .exponential = 8 },
                    .now_ms = transition_time,
                });
            }
        }
        if (hover) |id| {
            try self.animations.transition(.{ .owner = id, .lane = 2 }, .{
                .from_if_absent = 0,
                .to = 1,
                .duration_ms = 1440,
                .easing = .{ .exponential = 8 },
                .now_ms = transition_time,
            });
        }
        const next_hover_alpha = if (hover_visual) |id|
            self.animations.sample(.{ .owner = id, .lane = 2 }, time_ms) orelse 0
        else
            0;
        if (next_hover_alpha == 0 and hover == null) hover_visual = null;
        const prev_tree = self.tree_ptr;
        self.publishing_tree = tree;
        self.publishing_components = &staged_components;
        var publication_focus: PublicationFocus = .{ .app = self };
        self.focus_manager.reconcile(prev_tree, tree, .{
            .user = &publication_focus,
            .on_focus = PublicationFocus.onFocus,
            .on_cancel = PublicationFocus.onCancel,
        });
        if (publication_focus.change) |change| {
            // A publication may not write a model, so a chord held by the
            // consumer leaving the tree cannot be delivered here. Its input
            // waits for the frame to close, and the endpoint that owns the
            // keyboard stays registered until then. Nothing held keeps the
            // ordinary order, where that endpoint retires first.
            if (self.captureHeldChord()) {
                // Only this tree and these dense owners can still name the
                // widget losing the keyboard, so both are retained and the
                // whole change — focus_out included — waits for the delivery.
                // A consumer that releases its endpoint when it hears
                // focus_out must not be able to swallow input it already got.
                self.deferred_focus_tree = prev_tree;
                self.deferred_components.clearRetainingCapacity();
                var retired = self.components.iterator();
                while (retired.next()) |entry| {
                    self.deferred_components.putAssumeCapacity(
                        entry.key_ptr.*,
                        entry.value_ptr.*,
                    );
                }
                self.deferred_focus = change;
            } else {
                onFocusChanged(self, change);
            }
        }
        self.publishing_tree = null;
        self.publishing_components = null;
        self.components.clearRetainingCapacity();
        var dense_entries = staged_components.iterator();
        while (dense_entries.next()) |entry| {
            self.components.putAssumeCapacity(entry.key_ptr.*, entry.value_ptr.*);
        }
        self.identity_registry.map.clearRetainingCapacity();
        var mounts = staged_mounts.map.iterator();
        while (mounts.next()) |entry| {
            self.identity_registry.map.putAssumeCapacity(entry.key_ptr.*, entry.value_ptr.*);
        }
        // Every fallible step is behind us, so the staged overlay resolution
        // and its paint bands publish with the tree they belong to. A frame
        // that failed in an element hook or in band resolution never got
        // here, and the last committed routing and metadata stand.
        if (self.overlay) |overlay_frame| overlay_frame.commit();
        self.widget_identities.commitFrame();
        self.animations.pruneDead(&self.widget_identities);
        self.state_prev = state_dir;
        self.current = build_idx;
        self.tree_ptr = tree;
        self.surface = surface;
        self.frame_generation = generation;
        if (semantic_publication) |publication|
            publication.publisher.commitFocused(self.focus_manager.current);
        self.text_input.invalidateGeometry();
        self.pressed = next_pressed;
        self.press_visual = press_visual;
        self.hover_visual = hover_visual;
        self.last_time_ms = time_ms;
        self.press_alpha = next_press_alpha;
        self.hover_alpha = next_hover_alpha;
        published = true;
        for (tree.nodes.items) |node| {
            if (node.kind != .element) continue;
            const element_frame = node.kind.element;
            if (element_frame.ops.commit) |commit| commit(element_frame.payload, element_frame.phase);
        }
        if (gpu_frame == null) self.animations.framePresented(time_ms);
        self.flushInputNotifications();
        return .{
            .frame_number = frame_number,
            .time_ms = time_ms,
            .json = json,
            .tree = tree,
            .prev_tree = prev_tree,
            .semantic_snapshot = if (semantic_publication) |publication|
                publication.publisher.snapshot()
            else
                null,
            .hover = hover,
            .focus = self.focus_manager.current,
            .pressed = next_pressed,
            .visual_pressed = press_visual,
            .visual_hover = hover_visual,
            .press_alpha = next_press_alpha,
            .hover_alpha = next_hover_alpha,
        };
    }

    /// Inject a semantic accessibility action only on the committed tree.
    /// A readable previous snapshot never owns event dispatch.
    pub fn activate(self: *App, tree: *const WidgetTree, id: WidgetId) void {
        self.activateFrom(tree, id, .accessibility, 1);
    }
};

/// A held chord taken out for a deferred frame keeps its original input and
/// fires no action: the consumer that received the key press is the one that
/// receives its commit.
fn captureHeldReplay(raw: *anyopaque, replay: keymap.Replay) void {
    const self: *App = @ptrCast(@alignCast(raw));
    // The keymap replays at most its own bounded pending storage.
    std.debug.assert(self.held_len < self.held_events.len);
    self.held_events[self.held_len] = ownHeldInput(self, replay.input);
    self.held_len += 1;
}

/// Copy one captured event's borrowed text into the App's own store and
/// return the event naming it there. The keymap hands out slices into a
/// buffer it overwrites as soon as the next event arrives, so a held copy
/// that kept them would be rewritten by any input a listener injects
/// between the publication and the delivery.
fn ownHeldInput(self: *App, captured_event: Event) Event {
    var owned = captured_event;
    switch (owned) {
        .key_down => |*pressed| switch (pressed.logical) {
            .character => |text| pressed.logical = .{ .character = appendHeldText(self, text) },
            else => {},
        },
        .key_up => |*released| switch (released.logical) {
            .character => |text| released.logical = .{ .character = appendHeldText(self, text) },
            else => {},
        },
        .text_input => |*committed| committed.text = appendHeldText(self, committed.text),
        // The keymap buffers these three variants only. A new one carrying
        // borrowed text must be named here rather than passed through.
        else => unreachable,
    }
    return owned;
}

fn appendHeldText(self: *App, text: []const u8) []const u8 {
    const start = self.held_text_len;
    // max_held_text is the keymap's own worst case, so this never truncates.
    std.debug.assert(text.len <= self.held_text.len - start);
    @memcpy(self.held_text[start..][0..text.len], text);
    self.held_text_len = start + text.len;
    return self.held_text[start..self.held_text_len];
}

fn dropHeldAction(_: *anyopaque, _: keymap.Action) void {}

// --- tests ---------------------------------------------------------------

test "App: frame without a mounted root returns RootNotMounted" {
    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var app = try App.init(std.testing.allocator, &session);
    defer app.deinit();

    try std.testing.expectError(
        error.RootNotMounted,
        app.frame(1, .{ .width = 100, .height = 100 }),
    );
}

test "App: frame rejects a NaN surface width before root draw" {
    const Root = struct {
        const Self = @This();
        draw_count: usize = 0,

        pub fn draw(self: *Self, ctx: *DrawCtx) !void {
            self.draw_count += 1;
            _ = ctx;
        }
    };

    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var app = try App.init(std.testing.allocator, &session);
    defer app.deinit();

    var root: Root = .{};
    try app.mountRoot(Root, &root);

    try std.testing.expectError(
        error.InvalidStyle,
        app.frame(1, .{
            .width = std.math.nan(f32),
            .height = 600,
        }),
    );
    try std.testing.expectEqual(@as(usize, 0), root.draw_count);
}

/// Minimal counter component: a label that reflects `count` plus an
/// Increment button. Mirrors the §10 demo shape (minus the slider).
const Counter = struct {
    count: u32 = 0,
    label_buf: [32]u8 = @splat(0),

    pub fn draw(self: *Counter, ctx: *DrawCtx) anyerror!void {
        const text = try std.fmt.bufPrint(&self.label_buf, "Count: {d}", .{self.count});
        _ = try ctx.column(.{ .gap = 8 });
        defer ctx.pop();
        _ = try ctx.label(.{ .text = text });
        _ = try ctx.button(.{
            .key = .{ .static = "increment" },
            .label = "Increment",
            .on_click = Counter.onClick,
        });
    }

    pub fn onClick(self: *Counter) void {
        self.count += 1;
    }
};

/// First `.button` node in the tree. Node order is post-order (children
/// before containers) and ids are not positions — scan by kind, never by
/// index arithmetic.
fn firstButton(tree: *const WidgetTree) ?FrameNodeId {
    for (tree.nodes.items) |*n| {
        if (n.kind == .button) return n.id;
    }
    return null;
}

test "App: three frames with click injection persist state across frames" {
    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var app = try App.init(std.testing.allocator, &session);
    defer app.deinit();
    app.serialize_json = true;

    var counter: Counter = .{};
    try app.mountRoot(Counter, &counter);

    // Frame 1: find the first .button node in the frame tree and click it
    // while the tree is still valid (dies at the next frame's arena reset).
    const out1 = try app.frame(1, .{ .width = 800, .height = 600 });
    defer if (out1.json) |j| std.testing.allocator.free(j);
    const json1 = out1.json orelse return error.MissingFrameJson;
    try std.testing.expect(std.mem.indexOf(u8, json1, "Count: 0") != null);

    const btn = firstButton(out1.tree) orelse return error.MissingButton;
    const button_identity = (out1.tree.nodeConst(btn) orelse return error.MissingButton)
        .widget_id orelse return error.MissingWidgetIdentity;
    app.activate(out1.tree, button_identity);

    // Frames 2-3: the incremented count persists — no dirty tracking.
    const out2 = try app.frame(2, .{ .width = 800, .height = 600 });
    defer if (out2.json) |j| std.testing.allocator.free(j);
    const json2 = out2.json orelse return error.MissingFrameJson;
    try std.testing.expect(std.mem.indexOf(u8, json2, "Count: 1") != null);

    const out3 = try app.frame(3, .{ .width = 800, .height = 600 });
    defer if (out3.json) |j| std.testing.allocator.free(j);
    const json3 = out3.json orelse return error.MissingFrameJson;
    try std.testing.expect(std.mem.indexOf(u8, json3, "Count: 1") != null);
}

test "App: frame tree exposes button nodes owned by the mounted root" {
    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var app = try App.init(std.testing.allocator, &session);
    defer app.deinit();

    var counter: Counter = .{};
    try app.mountRoot(Counter, &counter);

    const out = try app.frame(1, .{ .width = 800, .height = 600 });
    defer if (out.json) |j| std.testing.allocator.free(j);

    // Every button binds its owner to the mounted root component (id 1), so
    // click dispatch can reach it.
    var found: usize = 0;
    for (out.tree.nodes.items) |n| {
        if (n.kind != .button) continue;
        found += 1;
        try std.testing.expectEqual(@as(FrameNodeId, @fromBackingInt(@intCast(1))), n.kind.button.owner);
    }
    try std.testing.expect(found >= 1);
}

test "App: click on an unknown id is a no-op and the next frame still renders" {
    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var app = try App.init(std.testing.allocator, &session);
    defer app.deinit();
    app.serialize_json = true;

    var counter: Counter = .{};
    try app.mountRoot(Counter, &counter);

    const out1 = try app.frame(1, .{ .width = 800, .height = 600 });
    defer if (out1.json) |j| std.testing.allocator.free(j);

    app.activate(out1.tree, .{
        .owner = app.widget_identities.owner,
        .slot = 999,
        .generation = 1,
    });

    const out2 = try app.frame(2, .{ .width = 800, .height = 600 });
    defer if (out2.json) |j| std.testing.allocator.free(j);
    const json = out2.json orelse return error.MissingFrameJson;
    try std.testing.expect(std.mem.indexOf(u8, json, "Count: 0") != null);
}

/// Read a display label from one snapshot without treating its dense id as identity.
fn firstLabelText(tree: *const WidgetTree) ?[]const u8 {
    for (tree.nodes.items) |node| {
        if (node.kind == .label) return node.kind.label.text;
    }
    return null;
}

test "App: ctx.state persists per node across frames, resets after unmount" {
    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var app = try App.init(std.testing.allocator, &session);
    defer app.deinit();

    const Comp = struct {
        const Self = @This();

        show: bool = true,
        last: ?*u32 = null, // the state pointer from the most recent draw

        pub fn draw(self: *Self, ctx: *DrawCtx) !void {
            self.last = null;
            if (!self.show) return; // node unmounted this frame
            const n = try ctx.state(u32, "count", 0);
            self.last = n;
            n.* += 1;
        }
    };
    var comp: Comp = .{};
    try app.mountRoot(Comp, &comp);

    // Frame 1: fresh node -> init 0, incremented to 1.
    const out1 = try app.frame(1, .{ .width = 100, .height = 100 });
    defer if (out1.json) |j| std.testing.allocator.free(j);
    const first_state = comp.last orelse return error.MissingState;
    try std.testing.expectEqual(@as(u32, 1), first_state.*);

    // Frame 2: the last version (1) was copied over -> 2.
    const out2 = try app.frame(2, .{ .width = 100, .height = 100 });
    defer if (out2.json) |j| std.testing.allocator.free(j);
    const second_state = comp.last orelse return error.MissingState;
    try std.testing.expectEqual(@as(u32, 2), second_state.*);

    // Frame 3: unmount — the node is not drawn; its state directory entry
    // dies with the frame.
    comp.show = false;
    const out3 = try app.frame(3, .{ .width = 100, .height = 100 });
    defer if (out3.json) |j| std.testing.allocator.free(j);
    try std.testing.expectEqual(@as(?*u32, null), comp.last);

    // Frame 4: remount -> fresh init again (0 -> 1), not 3.
    comp.show = true;
    const out4 = try app.frame(4, .{ .width = 100, .height = 100 });
    defer if (out4.json) |j| std.testing.allocator.free(j);
    const remounted_state = comp.last orelse return error.MissingState;
    try std.testing.expectEqual(@as(u32, 1), remounted_state.*);
}

test "App: current and previous frame snapshots remain readable" {
    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var app = try App.init(std.testing.allocator, &session);
    defer app.deinit();
    var counter: Counter = .{};
    try app.mountRoot(Counter, &counter);

    // Frame 1: no previous tree yet.
    const out1 = try app.frame(1, .{ .width = 800, .height = 600 });
    defer if (out1.json) |j| std.testing.allocator.free(j);
    try std.testing.expectEqual(@as(?*const WidgetTree, null), out1.prev_tree);

    const button_dense = firstButton(out1.tree) orelse return error.MissingButton;
    const button_id = (out1.tree.nodeConst(button_dense) orelse return error.MissingButton)
        .widget_id orelse return error.MissingWidgetIdentity;

    // Frame 2 changes the label without invalidating frame 1's snapshot.
    counter.count += 1;
    const out2 = try app.frame(2, .{ .width = 800, .height = 600 });
    defer if (out2.json) |j| std.testing.allocator.free(j);

    // prev_tree IS frame 1's tree — still fully readable after the swap.
    try std.testing.expect(out2.prev_tree == out1.tree);
    const previous_tree = out2.prev_tree orelse return error.MissingPreviousTree;
    const previous_label = firstLabelText(previous_tree) orelse return error.MissingLabelText;
    try std.testing.expectEqualStrings("Count: 0", previous_label);
    const current_label = firstLabelText(out2.tree) orelse return error.MissingLabelText;
    try std.testing.expectEqualStrings("Count: 1", current_label);

    try std.testing.expect(previous_tree.frameNode(button_id) != null);
    try std.testing.expect(out2.tree.frameNode(button_id) != null);

    // Frame 3: the swap advanced — prev_tree is now frame 2's tree.
    const out3 = try app.frame(3, .{ .width = 800, .height = 600 });
    defer if (out3.json) |j| std.testing.allocator.free(j);
    try std.testing.expect(out3.prev_tree == out2.tree);

    // Frame 2 remains readable as frame 3's previous snapshot.
    const previous_tree_after_swap = out3.prev_tree orelse return error.MissingPreviousTree;
    const previous_label_after_swap = firstLabelText(previous_tree_after_swap) orelse
        return error.MissingLabelText;
    try std.testing.expectEqualStrings("Count: 1", previous_label_after_swap);
}

test "App: driver — hover, click and slider drag through handle()" {
    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var app = try App.init(std.testing.allocator, &session);
    defer app.deinit();

    const Widgets = struct {
        const Self = @This();

        clicks: u32 = 0,
        volume: f32 = 0.5,

        pub fn draw(self: *Self, ctx: *DrawCtx) !void {
            _ = try ctx.column(.{});
            defer ctx.pop();
            _ = try ctx.slider(.{
                .key = .{ .static = "volume" },
                .label = "s",
                .value = &self.volume,
                .min = 0,
                .max = 1,
            });
            _ = try ctx.button(.{
                .key = .{ .static = "go" },
                .label = "go",
                .on_click = Self.onClick,
            });
        }

        fn onClick(self: *Self) void {
            self.clicks += 1;
        }
    };
    var widgets: Widgets = .{};
    try app.mountRoot(Widgets, &widgets);

    // The driver sizes the surface first; then frame 1 draws at 200x200.
    _ = try app.handle(.{ .resize = .{ .width = 200, .height = 200 } });
    const out1 = (try app.handle(.{ .frame = .{ .tick = 1, .time_ms = 0 } })) orelse
        return error.MissingFrameOutput;
    defer if (out1.json) |j| std.testing.allocator.free(j);

    const button_id = firstButton(out1.tree) orelse return error.MissingButton;
    const button_rect = widget.absoluteRect(out1.tree, button_id);
    try std.testing.expect(button_rect.w > 0);
    try std.testing.expect(button_rect.h > 0);
    const button_x = button_rect.x + button_rect.w * 0.1;
    const button_y = button_rect.y + button_rect.h / 2;

    _ = try app.handle(.{ .mouse_move = .{ .x = button_x, .y = button_y } });
    const out2 = (try app.handle(.{ .frame = .{ .tick = 2, .time_ms = 16 } })) orelse
        return error.MissingFrameOutput;
    defer if (out2.json) |j| std.testing.allocator.free(j);
    const hover_id = out2.hover orelse return error.MissingHoverTarget;
    try std.testing.expectEqual(
        (out1.tree.nodeConst(button_id) orelse return error.MissingButton).widget_id.?,
        hover_id,
    );

    // Click the button through the current laid-out hit box.
    _ = try app.handle(.{ .mouse_down = .{ .button = .left, .x = button_x, .y = button_y } });
    _ = try app.handle(.{ .mouse_up = .{ .button = .left, .x = button_x, .y = button_y } });
    try std.testing.expectEqual(@as(u32, 1), widgets.clicks);

    const slider_id = blk: {
        for (out1.tree.nodes.items) |*node| {
            if (node.kind == .slider) break :blk node.id;
        }
        unreachable;
    };
    const slider_rect = widget.absoluteRect(out1.tree, slider_id);
    try std.testing.expect(slider_rect.w > 0);
    try std.testing.expect(slider_rect.h > 0);
    const slider_y = slider_rect.y + slider_rect.h / 2;
    const slider_start_x = slider_rect.x + slider_rect.w * 0.05;
    const slider_value_x = slider_rect.x + slider_rect.w * 0.3;

    _ = try app.handle(.{ .mouse_down = .{ .button = .left, .x = slider_start_x, .y = slider_y } });
    _ = try app.handle(.{ .mouse_move = .{ .x = slider_value_x, .y = slider_y } });
    try std.testing.expectEqual(@as(f32, 0.3), widgets.volume);
    _ = try app.handle(.{ .mouse_up = .{ .button = .left, .x = slider_value_x, .y = slider_y } });
    // The drag ended: further moves do nothing.
    _ = try app.handle(.{
        .mouse_move = .{
            .x = slider_rect.x + slider_rect.w * 0.9,
            .y = slider_y,
        },
    });
    try std.testing.expectEqual(@as(f32, 0.3), widgets.volume);
}
test "App: mouse wheel scrolls the nearest ancestor and clamps offset" {
    const ScrollWidgets = struct {
        const Self = @This();

        state: ScrollState = .{},

        pub fn draw(self: *Self, ctx: *DrawCtx) !void {
            _ = try ctx.column(.{
                .flex_basis = 100,
                .scroll_state = &self.state,
                .scroll_axis = .vertical,
            });
            defer ctx.pop();
            _ = try ctx.label(.{ .text = "scroll target" });
        }
    };

    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var app = try App.init(std.testing.allocator, &session);
    defer app.deinit();
    var widgets: ScrollWidgets = .{};
    widgets.state.max_offset = .{ 0, 60 };
    widgets.state.offset = .{ 0, 10 };
    try app.mountRoot(ScrollWidgets, &widgets);

    _ = try app.handle(.{
        .resize = .{ .width = 200, .height = 100 },
    });
    const out = (try app.handle(.{
        .frame = .{ .tick = 1, .time_ms = 0 },
    })) orelse return error.MissingFrameOutput;
    // Layout computes max_offset from content overflow. Set a bounded
    // limit here so this test isolates wheel scaling and clamping.
    widgets.state.max_offset = .{ 0, 60 };
    defer if (out.json) |json| std.testing.allocator.free(json);

    // Negative wheel delta moves content down, increasing the scroll offset.
    _ = try app.handle(.{
        .mouse_wheel = .{
            .x = 1,
            .y = 1,
            .delta_x = 0,
            .delta_y = -2,
        },
    });
    try std.testing.expectEqual(@as(f32, 50), widgets.state.offset[1]);

    // A second negative delta stops at max_offset rather than overshooting.
    _ = try app.handle(.{
        .mouse_wheel = .{
            .x = 1,
            .y = 1,
            .delta_x = 0,
            .delta_y = -2,
        },
    });
    try std.testing.expectEqual(@as(f32, 60), widgets.state.offset[1]);

    // A large positive delta stops at the zero floor.
    _ = try app.handle(.{
        .mouse_wheel = .{
            .x = 1,
            .y = 1,
            .delta_x = 0,
            .delta_y = 10,
        },
    });
    try std.testing.expectEqual(@as(f32, 0), widgets.state.offset[1]);
}

test "App: mouse wheel stops at the nearest scroll ancestor" {
    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var app = try App.init(std.testing.allocator, &session);
    defer app.deinit();

    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();
    var outer_state: ScrollState = .{
        .max_offset = .{ 0, 100 },
    };
    var inner_state: ScrollState = .{
        .max_offset = .{ 0, 100 },
    };
    const outer_id: FrameNodeId = @fromBackingInt(@intCast(1));
    const inner_id: FrameNodeId = @fromBackingInt(@intCast(2));
    const child_id: FrameNodeId = @fromBackingInt(@intCast(3));

    try tree.nodes.append(std.testing.allocator, .{
        .id = child_id,
        .kind = .{ .label = .{ .text = "child" } },
        .parent = inner_id,
        .rect = .{ .x = 10, .y = 10, .w = 20, .h = 20 },
    });
    try tree.nodes.append(std.testing.allocator, .{
        .id = inner_id,
        .kind = .{ .column = .{} },
        .parent = outer_id,
        .rect = .{ .x = 0, .y = 0, .w = 100, .h = 100 },
        .paint = .{ .clip = true },
        .scroll = .{ .state = &inner_state, .axis = .vertical },
    });
    try tree.nodes.append(std.testing.allocator, .{
        .id = outer_id,
        .kind = .{ .column = .{} },
        .parent = .root,
        .rect = .{ .x = 0, .y = 0, .w = 100, .h = 100 },
        .paint = .{ .clip = true },
        .scroll = .{ .state = &outer_state, .axis = .vertical },
    });
    try tree.appendChild(inner_id, child_id);
    try tree.appendChild(outer_id, inner_id);
    app.tree_ptr = &tree;

    _ = try app.handle(.{
        .mouse_wheel = .{
            .x = 15,
            .y = 15,
            .delta_x = 0,
            .delta_y = -1,
        },
    });
    try std.testing.expectEqual(@as(f32, 20), inner_state.offset[1]);
    try std.testing.expectEqual(@as(f32, 0), outer_state.offset[1]);
}

test "App: keyboard — focus traversal, activate, slider arrows, escape" {
    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var app = try App.init(std.testing.allocator, &session);
    defer app.deinit();

    const Widgets = struct {
        const Self = @This();

        clicks: u32 = 0,
        volume: f32 = 0.5,

        pub fn draw(self: *Self, ctx: *DrawCtx) !void {
            _ = try ctx.column(.{});
            defer ctx.pop();
            _ = try ctx.slider(.{
                .key = .{ .static = "volume" },
                .label = "s",
                .value = &self.volume,
                .min = 0,
                .max = 1,
            });
            _ = try ctx.button(.{
                .key = .{ .static = "action-a" },
                .label = "a",
                .on_click = Self.onClick,
            });
            _ = try ctx.button(.{
                .key = .{ .static = "action-b" },
                .label = "b",
                .on_click = Self.onClick,
            });
        }

        fn onClick(self: *Self) void {
            self.clicks += 1;
        }
    };
    var widgets: Widgets = .{};
    try app.mountRoot(Widgets, &widgets);

    _ = try app.handle(.{ .resize = .{ .width = 200, .height = 200 } });
    const out1 = (try app.handle(.{ .frame = .{ .tick = 1, .time_ms = 0 } })) orelse
        return error.MissingFrameOutput;
    defer if (out1.json) |j| std.testing.allocator.free(j);

    // Focusable order (append order): slider, button a, button b.
    const ids = blk: {
        var found: [3]WidgetId = undefined;
        var n: usize = 0;
        for (out1.tree.nodes.items) |*node| {
            switch (node.kind) {
                .slider => {
                    found[n] = node.widget_id orelse return error.MissingWidgetIdentity;
                    n += 1;
                },
                .button => {
                    found[n] = node.widget_id orelse return error.MissingWidgetIdentity;
                    n += 1;
                },
                else => {},
            }
        }
        break :blk found;
    };

    // Tab: focus the first focusable (the slider); frame 2 reports it.
    _ = try app.handle(.{ .key_down = .{ .key = .tab, .shift = false } });
    const out2 = (try app.handle(.{ .frame = .{ .tick = 2, .time_ms = 16 } })) orelse
        return error.MissingFrameOutput;
    defer if (out2.json) |j| std.testing.allocator.free(j);
    const focused_id = out2.focus orelse return error.MissingFocus;
    try std.testing.expectEqual(ids[0], focused_id);

    // Tab: focus button a. Space: activate it -> clicks.
    _ = try app.handle(.{ .key_down = .{ .key = .tab, .shift = false } });
    _ = try app.handle(.{ .key_down = .{ .key = .space, .shift = false } });
    try std.testing.expectEqual(@as(u32, 1), widgets.clicks);

    // Right arrow on the focused slider: volume += 5% of the range.
    _ = try app.handle(.{ .key_down = .{ .key = .tab, .shift = true } }); // back to the slider
    _ = try app.handle(.{ .key_down = .{ .key = .right, .shift = false } });
    try std.testing.expectEqual(@as(f32, 0.55), widgets.volume);
    _ = try app.handle(.{ .key_down = .{ .key = .end, .shift = false } });
    try std.testing.expectEqual(@as(f32, 1), widgets.volume);

    // Escape clears focus.
    _ = try app.handle(.{ .key_down = .{ .key = .escape, .shift = false } });
    const out3 = (try app.handle(.{ .frame = .{ .tick = 3, .time_ms = 32 } })) orelse
        return error.MissingFrameOutput;
    defer if (out3.json) |j| std.testing.allocator.free(j);
    try std.testing.expectEqual(@as(?WidgetId, null), out3.focus);
}

test "App: keyed focus and press survive an unrelated insertion" {
    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var app = try App.init(std.testing.allocator, &session);
    defer app.deinit();

    const Comp = struct {
        const Self = @This();

        show_extra: bool = false,

        pub fn draw(self: *Self, ctx: *DrawCtx) !void {
            _ = try ctx.column(.{});
            defer ctx.pop();
            // The demo pattern: a conditional node ABOVE the button shifts
            // every following id when it appears.
            if (self.show_extra) _ = try ctx.label(.{ .text = "extra" });
            _ = try ctx.button(.{
                .key = .{ .static = "go" },
                .label = "go",
                .on_click = Self.noop,
            });
        }

        fn noop(self: *Self) void {
            _ = self;
        }
    };
    var comp: Comp = .{};
    try app.mountRoot(Comp, &comp);

    _ = try app.handle(.{ .resize = .{ .width = 200, .height = 200 } });
    const out1 = (try app.handle(.{ .frame = .{ .tick = 1, .time_ms = 0 } })) orelse
        return error.MissingFrameOutput;
    defer if (out1.json) |j| std.testing.allocator.free(j);

    // The button is the column's first child at (0,0,...); press it:
    // mouse_down focuses AND presses.
    _ = try app.handle(.{ .mouse_down = .{ .button = .left, .x = 5, .y = 5 } });
    const out2 = (try app.handle(.{ .frame = .{ .tick = 2, .time_ms = 16 } })) orelse
        return error.MissingFrameOutput;
    defer if (out2.json) |j| std.testing.allocator.free(j);
    try std.testing.expect(out2.focus != null);
    try std.testing.expect(out2.pressed != null);
    const stable_id = out2.focus orelse return error.MissingFocus;
    const old_dense = out2.tree.frameNode(stable_id) orelse return error.MissingButton;

    // Inserting a label shifts the dense id but not the keyed button handle.
    comp.show_extra = true;
    const out3 = (try app.handle(.{ .frame = .{ .tick = 3, .time_ms = 32 } })) orelse
        return error.MissingFrameOutput;
    defer if (out3.json) |j| std.testing.allocator.free(j);
    try std.testing.expectEqual(stable_id, out3.focus.?);
    try std.testing.expectEqual(stable_id, out3.pressed.?);
    const new_dense = out3.tree.frameNode(stable_id) orelse return error.MissingButton;
    try std.testing.expect(new_dense != old_dense);
    const displaced = out3.tree.nodeConst(old_dense) orelse return error.MissingStaleNode;
    try std.testing.expect(displaced.kind == .label);
}

test "App: keyboard — no focus: Tab lands on the first, Shift-Tab on the last" {
    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var app = try App.init(std.testing.allocator, &session);
    defer app.deinit();

    const Comp = struct {
        const Self = @This();

        pub fn draw(self: *Self, ctx: *DrawCtx) !void {
            _ = self;
            _ = try ctx.column(.{});
            defer ctx.pop();
            _ = try ctx.button(.{ .key = .{ .static = "a" }, .label = "a" });
            _ = try ctx.button(.{ .key = .{ .static = "b" }, .label = "b" });
            _ = try ctx.button(.{ .key = .{ .static = "c" }, .label = "c" });
        }
    };
    var comp: Comp = .{};
    try app.mountRoot(Comp, &comp);

    _ = try app.handle(.{ .resize = .{ .width = 200, .height = 200 } });
    const out1 = (try app.handle(.{ .frame = .{ .tick = 1, .time_ms = 0 } })) orelse
        return error.MissingFrameOutput;
    defer if (out1.json) |j| std.testing.allocator.free(j);

    const ids = blk: {
        var found: [3]WidgetId = undefined;
        var n: usize = 0;
        for (out1.tree.nodes.items) |*node| {
            if (node.kind != .button) continue;
            found[n] = node.widget_id orelse return error.MissingWidgetIdentity;
            n += 1;
        }
        try std.testing.expectEqual(@as(usize, 3), n);
        break :blk found;
    };

    // No focus + Tab -> the FIRST focusable.
    _ = try app.handle(.{ .key_down = .{ .key = .tab, .shift = false } });
    const out2 = (try app.handle(.{ .frame = .{ .tick = 2, .time_ms = 16 } })) orelse
        return error.MissingFrameOutput;
    defer if (out2.json) |j| std.testing.allocator.free(j);
    const first_focus = out2.focus orelse return error.MissingFocus;
    try std.testing.expectEqual(ids[0], first_focus);

    // No focus + Shift-Tab -> the LAST focusable (the old @mod(-2, count)
    // sentinel bug landed on count-2 instead of count-1).
    _ = try app.handle(.{ .key_down = .{ .key = .escape, .shift = false } });
    _ = try app.handle(.{ .key_down = .{ .key = .tab, .shift = true } });
    const out3 = (try app.handle(.{ .frame = .{ .tick = 3, .time_ms = 32 } })) orelse
        return error.MissingFrameOutput;
    defer if (out3.json) |j| std.testing.allocator.free(j);
    const last_focus = out3.focus orelse return error.MissingFocus;
    try std.testing.expectEqual(ids[2], last_focus);
}

test "App: keyboard — Space on a focused slider jumps to max; Enter stays button-only" {
    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var app = try App.init(std.testing.allocator, &session);
    defer app.deinit();

    const Comp = struct {
        const Self = @This();

        clicks: u32 = 0,
        volume: f32 = 0.2,

        pub fn draw(self: *Self, ctx: *DrawCtx) !void {
            _ = try ctx.column(.{});
            defer ctx.pop();
            _ = try ctx.slider(.{
                .key = .{ .static = "volume" },
                .label = "s",
                .value = &self.volume,
                .min = 0,
                .max = 1,
            });
            _ = try ctx.button(.{
                .key = .{ .static = "go" },
                .label = "go",
                .on_click = Self.onClick,
            });
        }

        fn onClick(self: *Self) void {
            self.clicks += 1;
        }
    };
    var comp: Comp = .{};
    try app.mountRoot(Comp, &comp);

    _ = try app.handle(.{ .resize = .{ .width = 200, .height = 200 } });
    const out1 = (try app.handle(.{ .frame = .{ .tick = 1, .time_ms = 0 } })) orelse
        return error.MissingFrameOutput;
    defer if (out1.json) |j| std.testing.allocator.free(j);

    // Tab -> focus the slider (first focusable); Space = End: value to max,
    // no click dispatched (sliders have no handler).
    _ = try app.handle(.{ .key_down = .{ .key = .tab, .shift = false } });
    _ = try app.handle(.{ .key_down = .{ .key = .space, .shift = false } });
    try std.testing.expectEqual(@as(f32, 1), comp.volume);
    try std.testing.expectEqual(@as(u32, 0), comp.clicks);

    // Enter on the same slider: still no click, value untouched.
    _ = try app.handle(.{ .key_down = .{ .key = .enter, .shift = false } });
    try std.testing.expectEqual(@as(f32, 1), comp.volume);
    try std.testing.expectEqual(@as(u32, 0), comp.clicks);
}

test "App: keyboard — focus traversal reaches the 70th focusable (no 64 cap)" {
    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var app = try App.init(std.testing.allocator, &session);
    defer app.deinit();

    const Many = struct {
        const Self = @This();

        pub fn draw(self: *Self, ctx: *DrawCtx) !void {
            _ = self;
            _ = try ctx.column(.{});
            defer ctx.pop();
            for (0..70) |index| {
                _ = try ctx.button(.{ .key = .{ .u64 = @as(u64, @intCast(index)) }, .label = "b" });
            }
        }
    };
    var comp: Many = .{};
    try app.mountRoot(Many, &comp);

    _ = try app.handle(.{ .resize = .{ .width = 200, .height = 600 } });
    const out = (try app.handle(.{ .frame = .{ .tick = 1, .time_ms = 0 } })) orelse
        return error.MissingFrameOutput;
    defer if (out.json) |j| std.testing.allocator.free(j);

    var button_ids: [70]WidgetId = undefined;
    var n: usize = 0;
    for (out.tree.nodes.items) |*node| {
        if (node.kind != .button) continue;
        button_ids[n] = node.widget_id orelse return error.MissingWidgetIdentity;
        n += 1;
    }
    try std.testing.expectEqual(@as(usize, 70), n);

    // 70 Tabs from no focus: the 70th Tab lands on the LAST focusable.
    // (The old fixed [64] buffer silently dropped focusables 65+, so the
    // 70th button was unreachable.)
    var last_focus: ?WidgetId = null;
    for (0..70) |i| {
        _ = try app.handle(.{ .key_down = .{ .key = .tab, .shift = false } });
        const f = (try app.handle(.{ .frame = .{ .tick = @intCast(2 + i), .time_ms = 0 } })) orelse
            return error.MissingFrameOutput;
        defer if (f.json) |j| std.testing.allocator.free(j);
        last_focus = f.focus;
    }
    const final_focus = last_focus orelse return error.MissingFocus;
    try std.testing.expectEqual(button_ids[69], final_focus);
}

test "App: persistent registries stay bounded across many frames (flat memory)" {
    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var app = try App.init(std.testing.allocator, &session);
    defer app.deinit();

    const Comp = struct {
        const Self = @This();

        pub fn draw(self: *Self, ctx: *DrawCtx) !void {
            _ = self;
            _ = try ctx.column(.{});
            defer ctx.pop();
            _ = try ctx.button(.{ .key = .{ .static = "a" }, .label = "a" });
            _ = try ctx.button(.{ .key = .{ .static = "b" }, .label = "b" });
        }
    };
    var comp: Comp = .{};
    try app.mountRoot(Comp, &comp);

    // 150 frames: the per-frame arenas retain their high-water, and the
    // persistent gpa state (component registry) must NOT grow — every
    // frame's component() puts overwrite the same 1 entry.
    var out: ?headless.FrameOutput = null;
    for (0..150) |i| {
        if (out) |o| if (o.json) |j| std.testing.allocator.free(j);
        out = try app.handle(.{ .frame = .{ .tick = @intCast(i + 1), .time_ms = @intCast(i * 16) } });
    }
    if (out) |o| if (o.json) |j| std.testing.allocator.free(j);

    // Exactly the root (id 1) — the two buttons are leaves, not components.
    try std.testing.expectEqual(@as(usize, 1), app.components.count());

    // The tree's node count is stable across frames (the last frame's tree
    // has the same shape as every other): column + 2 buttons + each
    // button's child label.
    const last = (try app.handle(.{ .frame = .{ .tick = 151, .time_ms = 2400 } })) orelse
        return error.MissingFrameOutput;
    defer if (last.json) |j| std.testing.allocator.free(j);
    try std.testing.expectEqual(@as(usize, 5), last.tree.nodes.items.len); // column + 2 buttons + 2 labels
}

test "App: deinit frees the component registry" {
    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var app = try App.init(std.testing.allocator, &session);
    var counter: Counter = .{};
    try app.mountRoot(Counter, &counter);
    // deinit without defer: the testing allocator's leak check after this
    // test is the assertion — a leak here fails the whole run.
    app.deinit();
}

test "present: press_alpha ramps over time and decays" {
    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var app = try App.init(std.testing.allocator, &session);
    defer app.deinit();

    const Comp = struct {
        const Self = @This();

        pub fn draw(self: *Self, ctx: *DrawCtx) !void {
            _ = self;
            _ = try ctx.column(.{ .gap = 8 });
            defer ctx.pop();
            _ = try ctx.button(.{ .key = .{ .static = "go" }, .label = "go" });
            _ = try ctx.label(.{ .text = "x" });
        }
    };
    var comp: Comp = .{};
    try app.mountRoot(Comp, &comp);

    _ = try app.handle(.{ .resize = .{ .width = 200, .height = 200 } });
    const out1 = (try app.handle(.{ .frame = .{ .tick = 1, .time_ms = 0 } })) orelse
        return error.MissingFrameOutput;
    defer if (out1.json) |j| std.testing.allocator.free(j);
    // First frame: dt = 0 (nothing happened between frames), so both
    // alphas sit exactly at 0.
    try std.testing.expectEqual(@as(f32, 0), out1.press_alpha);
    try std.testing.expectEqual(@as(f32, 0), out1.hover_alpha);

    // The button's center from the laid-out tree (the column stretches
    // the button to the surface width) — the hit position for press/hover.
    const center = blk: {
        for (out1.tree.nodes.items) |*n| {
            if (n.kind == .button) break :blk .{ n.rect.x + n.rect.w / 2, n.rect.y + n.rect.h / 2 };
        }
        unreachable;
    };

    // Press the button: mouse_down sets pressed; the ramp starts from the
    // current press_alpha (near 0). dt = 100ms -> k_press =
    // 1-exp(-100/100) ≈ 0.632, one pole from 0 (tau 100ms).
    _ = try app.handle(.{ .mouse_move = .{ .x = center[0], .y = center[1] } });
    _ = try app.handle(.{ .mouse_down = .{ .button = .left, .x = center[0], .y = center[1] } });
    const out2 = (try app.handle(.{ .frame = .{ .tick = 2, .time_ms = 100 } })) orelse
        return error.MissingFrameOutput;
    defer if (out2.json) |j| std.testing.allocator.free(j);
    try std.testing.expect(out2.pressed != null);
    try std.testing.expectApproxEqAbs(@as(f32, 0.632), out2.press_alpha, 0.05);
    try std.testing.expect(out2.press_alpha > 0.5 and out2.press_alpha < 0.8);

    // A second pole at the same dt: 0.632 + (1-0.632)*0.632 ≈ 0.865.
    const out3 = (try app.handle(.{ .frame = .{ .tick = 3, .time_ms = 200 } })) orelse
        return error.MissingFrameOutput;
    defer if (out3.json) |j| std.testing.allocator.free(j);
    try std.testing.expectApproxEqAbs(@as(f32, 0.865), out3.press_alpha, 0.05);
    try std.testing.expect(out3.press_alpha > 0.8);

    // Release: the target drops to 0 and press_alpha decays one pole
    // toward it: 0.865 * exp(-100/100) ≈ 0.318.
    _ = try app.handle(.{ .mouse_up = .{ .button = .left, .x = center[0], .y = center[1] } });
    const out4 = (try app.handle(.{ .frame = .{ .tick = 4, .time_ms = 300 } })) orelse
        return error.MissingFrameOutput;
    defer if (out4.json) |j| std.testing.allocator.free(j);
    try std.testing.expectApproxEqAbs(@as(f32, 0.318), out4.press_alpha, 0.05);
    try std.testing.expect(out4.press_alpha < 0.35);

    // The pointer leaves the window: hover_alpha (ramped to ≈0.811 while
    // hovering, tau 180ms) decays one pole toward 0: ≈0.465 — the fade
    // must still be mid-flight, not snapped.
    _ = try app.handle(.{ .mouse_leave = {} });
    const out5 = (try app.handle(.{ .frame = .{ .tick = 5, .time_ms = 400 } })) orelse
        return error.MissingFrameOutput;
    defer if (out5.json) |j| std.testing.allocator.free(j);
    try std.testing.expect(out5.hover_alpha > 0.3 and out5.hover_alpha < 0.6);

    // Move back over the button: re-enter (null → node) is NOT a reset —
    // the fade ramps from the decayed value: 0.465 + (1-0.465)*0.426 ≈
    // 0.693 (past the midpoint, still easing).
    _ = try app.handle(.{ .mouse_move = .{ .x = center[0], .y = center[1] } });
    const out6 = (try app.handle(.{ .frame = .{ .tick = 6, .time_ms = 500 } })) orelse
        return error.MissingFrameOutput;
    defer if (out6.json) |j| std.testing.allocator.free(j);
    try std.testing.expectApproxEqAbs(@as(f32, 0.693), out6.hover_alpha, 0.05);
    try std.testing.expect(out6.hover_alpha > 0.65);

    // Moving to a display-only label leaves the keyed hover target.
    // Its opacity decays toward zero without aliasing another widget.
    const label_center = blk: {
        const btn_id = out6.tree.frameNode(out6.hover orelse
            return error.MissingHoverTarget) orelse return error.MissingButton;
        for (out6.tree.nodes.items) |*n| {
            if (n.kind != .label) continue;
            if (n.id == btn_id) continue;
            var par = n.parent;
            var inside_button = false;
            while (par != .root) {
                if (par == btn_id) {
                    inside_button = true;
                    break;
                }
                var found: FrameNodeId = .root;
                for (out6.tree.nodes.items) |*pn| {
                    if (pn.id == par) {
                        found = pn.parent;
                        break;
                    }
                }
                par = found;
            }
            if (inside_button) continue;
            break :blk .{ n.rect.x + n.rect.w / 2, n.rect.y + n.rect.h / 2 };
        }
        unreachable;
    };
    _ = try app.handle(.{ .mouse_move = .{ .x = label_center[0], .y = label_center[1] } });
    const out7 = (try app.handle(.{ .frame = .{ .tick = 7, .time_ms = 600 } })) orelse
        return error.MissingFrameOutput;
    defer if (out7.json) |j| std.testing.allocator.free(j);
    try std.testing.expect(out7.hover == null);
    try std.testing.expectApproxEqAbs(@as(f32, 0.397), out7.hover_alpha, 0.05);

    // Monotone per pole — no overshoot: each alpha strictly moves toward
    // its current target, and every value stays in [0, 1].
    try std.testing.expect(out3.press_alpha > out2.press_alpha);
    try std.testing.expect(out4.press_alpha < out3.press_alpha);
    try std.testing.expect(out5.hover_alpha < out4.hover_alpha);
    try std.testing.expect(out6.hover_alpha > out5.hover_alpha);
    try std.testing.expect(out7.hover_alpha > 0.3 and out7.hover_alpha < 0.55);
    try std.testing.expect(out6.press_alpha >= 0 and out6.press_alpha <= 1);
    try std.testing.expect(out6.hover_alpha >= 0 and out6.hover_alpha <= 1);
}

test "App: same-key component identity is stable across frames" {
    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var app = try App.init(std.testing.allocator, &session);
    defer app.deinit();

    const Child = struct {
        const Self = @This();

        pub fn draw(self: *Self, ctx: *DrawCtx) !void {
            _ = self;
            _ = ctx;
        }
    };
    const Root = struct {
        const Self = @This();
        child: Child = .{},

        pub fn draw(self: *Self, ctx: *DrawCtx) !void {
            try ctx.component(Child, .{ .key = .{ .static = "child" } }, &self.child);
        }
    };

    var root: Root = .{};
    try app.mountRoot(Root, &root);
    _ = try app.frame(1, .{ .width = 100, .height = 100 });
    const child_identity = ComponentId.child(.root, .{ .static = "child" });
    const root_entry = app.identity_registry.map.get(child_identity) orelse
        return error.MissingComponentIdentity;
    try std.testing.expectEqual(@as(u64, 1), root_entry.last_seen_frame);

    _ = try app.frame(2, .{ .width = 100, .height = 100 });
    const entry = app.identity_registry.map.get(child_identity) orelse
        return error.MissingComponentIdentity;
    try std.testing.expectEqual(child_identity, ComponentId.child(.root, .{ .static = "child" }));
    try std.testing.expectEqual(@as(u64, 2), entry.last_seen_frame);
}

test "App: duplicate same-key sibling components are rejected" {
    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var app = try App.init(std.testing.allocator, &session);
    defer app.deinit();

    const Child = struct {
        const Self = @This();

        pub fn draw(self: *Self, ctx: *DrawCtx) !void {
            _ = self;
            _ = ctx;
        }
    };
    const Root = struct {
        const Self = @This();
        first: Child = .{},
        second: Child = .{},

        pub fn draw(self: *Self, ctx: *DrawCtx) !void {
            try ctx.component(Child, .{ .key = .{ .static = "duplicate" } }, &self.first);
            try ctx.component(Child, .{ .key = .{ .static = "duplicate" } }, &self.second);
        }
    };

    var root: Root = .{};
    try app.mountRoot(Root, &root);
    try std.testing.expectError(
        error.DuplicateComponentIdentity,
        app.frame(1, .{ .width = 100, .height = 100 }),
    );
}

test "App: component-scoped state survives a preceding sibling insertion" {
    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var app = try App.init(std.testing.allocator, &session);
    defer app.deinit();

    const Child = struct {
        const Self = @This();
        observed: u32 = 0,

        pub fn draw(self: *Self, ctx: *DrawCtx) !void {
            const value = try ctx.state(u32, "value", 0);
            self.observed = value.*;
            value.* += 1;
        }
    };
    const Root = struct {
        const Self = @This();
        child: Child = .{},
        insert_sibling: bool = false,

        pub fn draw(self: *Self, ctx: *DrawCtx) !void {
            if (self.insert_sibling) {
                _ = try ctx.label(.{ .text = "inserted" });
            }
            try ctx.component(Child, .{ .key = .{ .static = "stateful-child" } }, &self.child);
        }
    };

    var root: Root = .{};
    try app.mountRoot(Root, &root);
    _ = try app.frame(1, .{ .width = 100, .height = 100 });
    try std.testing.expectEqual(@as(u32, 0), root.child.observed);

    root.insert_sibling = true;
    _ = try app.frame(2, .{ .width = 100, .height = 100 });
    try std.testing.expectEqual(@as(u32, 1), root.child.observed);
}
test "App: bound controls activate, focus traversal skips display widgets, and radios wrap" {
    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var app = try App.init(std.testing.allocator, &session);
    defer app.deinit();

    const Controls = struct {
        const Self = @This();

        checked: bool = false,
        enabled: bool = false,
        selected: ?u32 = null,
        other_selected: ?u32 = null,

        pub fn draw(self: *Self, ctx: *DrawCtx) !void {
            _ = try ctx.column(.{});
            defer ctx.pop();
            _ = try ctx.checkbox(.{
                .key = .{ .static = "check" },
                .label = "check",
                .value = &self.checked,
            });
            _ = try ctx.switchControl(.{
                .key = .{ .static = "switch" },
                .label = "switch",
                .value = &self.enabled,
            });
            _ = try ctx.radio(.{
                .key = .{ .static = "primary-one" },
                .label = "one",
                .selected = &self.selected,
                .option = 1,
            });
            _ = try ctx.radio(.{
                .key = .{ .static = "other-nine" },
                .label = "other group",
                .selected = &self.other_selected,
                .option = 9,
            });
            _ = try ctx.radio(.{
                .key = .{ .static = "primary-two" },
                .label = "two",
                .selected = &self.selected,
                .option = 2,
            });
            _ = try ctx.progress(.{ .label = "", .value = 0.5, .min = 0, .max = 1 });
            _ = try ctx.separator(.{});
        }
    };
    var controls: Controls = .{};
    try app.mountRoot(Controls, &controls);
    const output = try app.frame(
        1,
        .{ .width = 320, .height = 320 },
    );
    defer if (output.json) |json| std.testing.allocator.free(json);

    var focus_ids: [5]WidgetId = undefined;
    var focus_count: usize = 0;
    var checkbox_id: ?WidgetId = null;
    var switch_id: ?WidgetId = null;
    var first_radio_id: ?WidgetId = null;
    var second_radio_id: ?WidgetId = null;
    for (output.tree.nodes.items) |*node| {
        switch (node.kind) {
            .checkbox => {
                checkbox_id = node.widget_id;
                focus_ids[focus_count] = node.widget_id orelse return error.MissingWidgetIdentity;
                focus_count += 1;
            },
            .switch_control => {
                switch_id = node.widget_id;
                focus_ids[focus_count] = node.widget_id orelse return error.MissingWidgetIdentity;
                focus_count += 1;
            },
            .radio => |radio| {
                const identity = node.widget_id orelse return error.MissingWidgetIdentity;
                focus_ids[focus_count] = identity;
                focus_count += 1;
                if (radio.option == 1) first_radio_id = identity;
                if (radio.option == 2) second_radio_id = identity;
            },
            else => {},
        }
    }
    try std.testing.expectEqual(@as(usize, focus_ids.len), focus_count);
    const checkbox = checkbox_id orelse return error.MissingCheckbox;
    const switch_control = switch_id orelse return error.MissingSwitch;
    const first_radio = first_radio_id orelse return error.MissingFirstRadio;
    const second_radio = second_radio_id orelse return error.MissingSecondRadio;

    // Progress and separator are present in the tree but are not tab stops.
    for (0..focus_ids.len + 1) |index| {
        _ = try app.handle(.{
            .key_down = .{ .key = .tab, .shift = false },
        });
        const focused = app.focus_manager.current orelse return error.MissingFocus;
        try std.testing.expectEqual(focus_ids[index % focus_ids.len], focused);
    }

    // Seed focus the way the App itself moves it, so the radio navigation below
    // starts from a change the App routed rather than a silent write.
    _ = app.focus_manager.set(output.tree, first_radio, app.focusObserver());
    _ = try app.handle(.{
        .key_down = .{ .key = .right, .shift = false },
    });
    try std.testing.expectEqual(second_radio, app.focus_manager.current.?);
    try std.testing.expectEqual(@as(?u32, 2), controls.selected);
    try std.testing.expectEqual(@as(?u32, null), controls.other_selected);
    _ = try app.handle(.{
        .key_down = .{ .key = .down, .shift = false },
    });
    try std.testing.expectEqual(first_radio, app.focus_manager.current.?);
    try std.testing.expectEqual(@as(?u32, 1), controls.selected);
    _ = try app.handle(.{
        .key_down = .{ .key = .up, .shift = false },
    });
    try std.testing.expectEqual(second_radio, app.focus_manager.current.?);
    try std.testing.expectEqual(@as(?u32, 2), controls.selected);

    app.activate(output.tree, switch_control);
    try std.testing.expect(controls.enabled);

    const checkbox_rect = widget.absoluteRect(
        output.tree,
        output.tree.frameNode(checkbox) orelse return error.MissingCheckbox,
    );
    const checkbox_x = checkbox_rect.x + checkbox_rect.w / 2;
    const checkbox_y = checkbox_rect.y + checkbox_rect.h / 2;
    _ = try app.handle(.{
        .mouse_down = .{ .button = .left, .x = checkbox_x, .y = checkbox_y },
    });
    try std.testing.expect(!controls.checked);
    try std.testing.expectEqual(checkbox, app.focus_manager.current.?);
    _ = try app.handle(.{
        .mouse_up = .{ .button = .left, .x = checkbox_x, .y = checkbox_y },
    });
    try std.testing.expect(controls.checked);
    _ = try app.handle(.{
        .key_down = .{ .key = .enter, .shift = false },
    });
    try std.testing.expect(!controls.checked);
    _ = try app.handle(.{
        .key_down = .{ .key = .space, .shift = false },
    });
    try std.testing.expect(controls.checked);

    app.activate(output.tree, first_radio);
    try std.testing.expectEqual(@as(?u32, 1), controls.selected);
    const radio_rect = widget.absoluteRect(
        output.tree,
        output.tree.frameNode(second_radio) orelse return error.MissingSecondRadio,
    );
    _ = try app.handle(.{
        .mouse_down = .{
            .button = .left,
            .x = radio_rect.x + radio_rect.w / 2,
            .y = radio_rect.y + radio_rect.h / 2,
        },
    });
    try std.testing.expectEqual(@as(?u32, 1), controls.selected);
    _ = try app.handle(.{ .mouse_up = .{
        .button = .left,
        .x = radio_rect.x + radio_rect.w / 2,
        .y = radio_rect.y + radio_rect.h / 2,
    } });
    try std.testing.expectEqual(@as(?u32, 2), controls.selected);
    try std.testing.expectEqual(second_radio, app.focus_manager.current.?);
}

test "api-w02 focused button survives same-kind insertion before it" {
    const Buttons = struct {
        const Self = @This();
        insert_first: bool = false,
        a_clicks: u32 = 0,
        b_clicks: u32 = 0,

        pub fn draw(self: *Self, ctx: *DrawCtx) !void {
            _ = try ctx.column(.{ .gap = 8 });
            defer ctx.pop();
            if (self.insert_first) {
                _ = try ctx.button(.{
                    .key = .{ .static = "a" },
                    .label = "A",
                    .width = 120,
                    .height = 40,
                    .on_click = Self.clickA,
                });
            }
            _ = try ctx.button(.{
                .key = .{ .static = "b" },
                .label = "B",
                .width = 120,
                .height = 40,
                .on_click = Self.clickB,
            });
        }

        fn clickA(self: *Self) void {
            self.a_clicks += 1;
        }

        fn clickB(self: *Self) void {
            self.b_clicks += 1;
        }
    };

    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var app = try App.init(std.testing.allocator, &session);
    defer app.deinit();
    var buttons: Buttons = .{};
    try app.mountRoot(Buttons, &buttons);
    const first = try app.frame(1, .{ .width = 200, .height = 160 });
    defer if (first.json) |json| std.testing.allocator.free(json);
    const original = firstButton(first.tree) orelse return error.MissingButton;
    const original_id = (first.tree.nodeConst(original) orelse return error.MissingButton)
        .widget_id orelse return error.MissingWidgetIdentity;
    const rect = widget.absoluteRect(first.tree, original);
    _ = try app.handle(.{ .mouse_down = .{
        .button = .left,
        .x = rect.x + rect.w / 2,
        .y = rect.y + rect.h / 2,
    } });
    _ = try app.handle(.{ .mouse_up = .{
        .button = .left,
        .x = rect.x + rect.w / 2,
        .y = rect.y + rect.h / 2,
    } });
    try std.testing.expectEqual(@as(u32, 1), buttons.b_clicks);
    try std.testing.expectEqual(original_id, app.focus_manager.current.?);

    buttons.insert_first = true;
    const second = try app.frame(2, .{ .width = 200, .height = 160 });
    defer if (second.json) |json| std.testing.allocator.free(json);
    try std.testing.expectEqual(original_id, app.focus_manager.current.?);
    try std.testing.expect(
        (second.tree.frameNode(original_id) orelse return error.MissingButton) != original,
    );
    _ = try app.handle(.{ .key_down = .{ .key = .enter, .shift = false } });
    try std.testing.expectEqual(@as(u32, 0), buttons.a_clicks);
    try std.testing.expectEqual(@as(u32, 2), buttons.b_clicks);
}

test "api-w02 duplicate widget key aborts without replacing a usable frame" {
    const Root = struct {
        const Self = @This();
        duplicate: bool = false,
        last_tick: u32 = 0,
        observed: u32 = 0,
        clicks: u32 = 0,

        pub fn draw(self: *Self, ctx: *DrawCtx) !void {
            self.last_tick = ctx.frame_info.?.tick;
            const state = try ctx.state(u32, "counter", 0);
            state.* += 1;
            self.observed = state.*;
            _ = try ctx.button(.{
                .key = .{ .static = "primary" },
                .label = "Primary",
                .on_click = Self.onClick,
            });
            if (self.duplicate) {
                _ = try ctx.button(.{
                    .key = .{ .static = "primary" },
                    .label = "Another caption",
                });
            }
        }

        fn onClick(self: *Self) void {
            self.clicks += 1;
        }
    };

    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var app = try App.init(std.testing.allocator, &session);
    defer app.deinit();
    var root: Root = .{};
    try app.mountRoot(Root, &root);
    const first = (try app.handle(.{
        .frame = .{ .tick = 1, .time_ms = 100 },
    })) orelse return error.MissingFrameOutput;
    try std.testing.expectEqual(@as(u32, 1), root.last_tick);
    const primary = app.widgetIdForKey(.root, .{ .static = "primary" }) orelse
        return error.MissingWidgetIdentity;
    const first_node = first.tree.frameNode(primary) orelse return error.MissingButton;
    const rect = widget.absoluteRect(first.tree, first_node);
    _ = try app.handle(.{ .mouse_down = .{
        .button = .left,
        .x = rect.x + rect.w / 2,
        .y = rect.y + rect.h / 2,
    } });
    try std.testing.expectEqual(@as(u32, 0), root.clicks);
    const committed_state = app.state_prev;

    root.duplicate = true;
    try std.testing.expectError(error.DuplicateWidgetKey, app.handle(.{
        .frame = .{ .tick = 2, .time_ms = 200 },
    }));
    try std.testing.expectEqual(@as(u64, 1), app.frame_generation);
    try std.testing.expect(app.tree_ptr == first.tree);
    try std.testing.expect(app.state_prev == committed_state);
    try std.testing.expectEqual(primary, app.focus_manager.current.?);
    try std.testing.expectEqual(primary, app.pressed.?);
    try std.testing.expectEqual(@as(u64, 100), app.last_time_ms);
    try std.testing.expectEqual(@as(f32, 0), app.press_alpha);
    try std.testing.expectEqual(@as(u32, 2), root.last_tick);
    try std.testing.expectEqual(primary, app.widgetIdForKey(
        .root,
        .{ .static = "primary" },
    ).?);
    app.activate(first.tree, primary);
    try std.testing.expectEqual(@as(u32, 1), root.clicks);

    root.duplicate = false;
    const recovered = (try app.handle(.{
        .frame = .{ .tick = 3, .time_ms = 200 },
    })) orelse return error.MissingFrameOutput;
    try std.testing.expect(recovered.prev_tree == first.tree);
    try std.testing.expectEqual(@as(u32, 2), root.observed);
    try std.testing.expectEqual(primary, recovered.focus.?);
    try std.testing.expectEqual(primary, recovered.pressed.?);
    try std.testing.expectApproxEqAbs(@as(f32, 0.632), recovered.press_alpha, 0.05);
    try std.testing.expectEqual(@as(u32, 3), root.last_tick);
    try std.testing.expect(first.tree.frameNode(primary) != null);
    try std.testing.expect(recovered.tree.frameNode(primary) != null);
}

test "api-w02 removal and remount retire focus and reject stale clicks" {
    const Root = struct {
        const Self = @This();
        show_a: bool = true,
        a_clicks: u32 = 0,
        b_clicks: u32 = 0,

        pub fn draw(self: *Self, ctx: *DrawCtx) !void {
            _ = try ctx.column(.{});
            defer ctx.pop();
            if (self.show_a) {
                _ = try ctx.button(.{
                    .key = .{ .static = "a" },
                    .label = "A",
                    .on_click = Self.clickA,
                });
            }
            _ = try ctx.button(.{
                .key = .{ .static = "b" },
                .label = "B",
                .on_click = Self.clickB,
            });
        }

        fn clickA(self: *Self) void {
            self.a_clicks += 1;
        }
        fn clickB(self: *Self) void {
            self.b_clicks += 1;
        }
    };

    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var app = try App.init(std.testing.allocator, &session);
    defer app.deinit();
    var root: Root = .{};
    try app.mountRoot(Root, &root);
    const first = try app.frame(1, .{ .width = 200, .height = 200 });
    const old_a = app.widgetIdForKey(.root, .{ .static = "a" }) orelse
        return error.MissingWidgetIdentity;
    const b = app.widgetIdForKey(.root, .{ .static = "b" }) orelse
        return error.MissingWidgetIdentity;
    _ = try app.handle(.{ .key_down = .{ .key = .tab, .shift = false } });
    try std.testing.expectEqual(old_a, app.focus_manager.current.?);

    root.show_a = false;
    const second = try app.frame(2, .{ .width = 200, .height = 200 });
    try std.testing.expect(second.prev_tree == first.tree);
    try std.testing.expectEqual(b, app.focus_manager.current.?);
    try std.testing.expect(second.tree.frameNode(old_a) == null);
    try std.testing.expect(first.tree.frameNode(old_a) != null);
    try std.testing.expect(app.widgetIdForKey(.root, .{ .static = "a" }) == null);
    app.activate(first.tree, b); // Readable old snapshot cannot dispatch into the current frame.
    try std.testing.expectEqual(@as(u32, 0), root.b_clicks);
    app.activate(second.tree, b);
    try std.testing.expectEqual(@as(u32, 1), root.b_clicks);

    root.show_a = true;
    const third = try app.frame(3, .{ .width = 200, .height = 200 });
    const new_a = app.widgetIdForKey(.root, .{ .static = "a" }) orelse
        return error.MissingWidgetIdentity;
    try std.testing.expect(!old_a.eql(new_a));
    app.activate(third.tree, old_a);
    try std.testing.expectEqual(@as(u32, 0), root.a_clicks);
    app.activate(third.tree, new_a);
    try std.testing.expectEqual(@as(u32, 1), root.a_clicks);
}

test "api-w02 GPU rollback and mount replacement wait once per batch" {
    const Wait = struct {
        var calls: usize = 0;
        fn complete() void {
            calls += 1;
        }
    };
    const Child = struct {
        const Self = @This();
        inits: usize = 0,
        deinits: usize = 0,
        fail_init: bool = false,

        pub fn draw(_: *Self, _: *DrawCtx) !void {}
        pub fn initGpu(self: *Self, _: *GpuEndpoint) !void {
            self.inits += 1;
            if (self.fail_init) return error.StagedInitFailure;
        }
        pub fn deinitGpu(self: *Self, _: *GpuEndpoint) void {
            self.deinits += 1;
        }
    };
    const Root = struct {
        const Self = @This();
        a: Child = .{},
        b: Child = .{},
        replacement: Child = .{},
        root_inits: usize = 0,
        root_deinits: usize = 0,
        show_a: bool = true,
        show_b: bool = false,
        replace_b: bool = false,
        fail_draw: bool = false,

        pub fn draw(self: *Self, ctx: *DrawCtx) !void {
            if (self.show_a) {
                try ctx.component(Child, .{ .key = .{ .static = "a" } }, &self.a);
            }
            if (self.show_b) {
                const ptr = if (self.replace_b) &self.replacement else &self.b;
                try ctx.component(Child, .{ .key = .{ .static = "b" } }, ptr);
            }
            if (self.fail_draw) return error.StagedDrawFailure;
        }
        pub fn initGpu(self: *Self, _: *GpuEndpoint) !void {
            self.root_inits += 1;
        }
        pub fn deinitGpu(self: *Self, _: *GpuEndpoint) void {
            self.root_deinits += 1;
        }
    };

    Wait.calls = 0;
    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var app = try App.init(std.testing.allocator, &session);
    defer app.deinit();
    var root: Root = .{};
    try app.mountRoot(Root, &root);
    var gpu: noapi.Gpu = undefined;
    var endpoint: GpuEndpoint = .{
        .gpu = &gpu,
        .retirement_wait_for_test = Wait.complete,
    };
    try app.attachGpu(&endpoint);
    const first = try app.frame(1, .{ .width = 100, .height = 100 });
    try std.testing.expectEqual(@as(usize, 1), root.root_inits);
    try std.testing.expectEqual(@as(usize, 0), root.root_deinits);
    try std.testing.expectEqual(@as(usize, 0), Wait.calls);
    try std.testing.expectEqual(@as(usize, 1), root.a.inits);

    root.show_b = true;
    root.fail_draw = true;
    try std.testing.expectError(
        error.StagedDrawFailure,
        app.frame(2, .{ .width = 100, .height = 100 }),
    );
    try std.testing.expect(app.tree_ptr == first.tree);
    try std.testing.expectEqual(@as(u64, 1), app.frame_generation);
    try std.testing.expectEqual(@as(usize, 1), root.b.inits);
    try std.testing.expectEqual(@as(usize, 1), root.b.deinits);
    try std.testing.expectEqual(@as(usize, 0), root.a.deinits);
    try std.testing.expectEqual(@as(usize, 1), Wait.calls);

    root.fail_draw = false;
    root.b.fail_init = true;
    try std.testing.expectError(
        error.StagedInitFailure,
        app.frame(2, .{ .width = 100, .height = 100 }),
    );
    try std.testing.expectEqual(@as(usize, 2), root.b.inits);
    try std.testing.expectEqual(@as(usize, 2), root.b.deinits);
    try std.testing.expectEqual(@as(usize, 2), Wait.calls);
    try std.testing.expectEqual(@as(usize, 0), root.a.deinits);

    root.b.fail_init = false;
    _ = try app.frame(2, .{ .width = 100, .height = 100 });
    try std.testing.expectEqual(@as(usize, 3), root.b.inits);
    try std.testing.expectEqual(@as(usize, 2), Wait.calls);
    root.replace_b = true;
    _ = try app.frame(3, .{ .width = 100, .height = 100 });
    try std.testing.expectEqual(@as(usize, 1), root.replacement.inits);
    try std.testing.expectEqual(@as(usize, 3), root.b.deinits);
    try std.testing.expectEqual(@as(usize, 3), Wait.calls);
    try std.testing.expectEqual(@as(usize, 0), root.a.deinits);

    root.show_a = false;
    root.show_b = false;
    _ = try app.frame(4, .{ .width = 100, .height = 100 });
    try std.testing.expectEqual(@as(usize, 1), root.a.deinits);
    try std.testing.expectEqual(@as(usize, 1), root.replacement.deinits);
    try std.testing.expectEqual(@as(usize, 4), Wait.calls);
    app.detachGpu();
    try std.testing.expectEqual(@as(usize, 1), root.root_deinits);
    try std.testing.expectEqual(@as(usize, 5), Wait.calls);
}

test "api-w02 slider capture follows its key and clears when removed" {
    const Sliders = struct {
        const Self = @This();
        show_a: bool = false,
        show_b: bool = true,
        a: f32 = 0.2,
        b: f32 = 0.2,

        pub fn draw(self: *Self, ctx: *DrawCtx) !void {
            _ = try ctx.column(.{ .gap = 8 });
            defer ctx.pop();
            if (self.show_a) {
                _ = try ctx.slider(.{
                    .key = .{ .static = "a" },
                    .label = "A",
                    .value = &self.a,
                    .min = 0,
                    .max = 1,
                    .width = 120,
                    .height = 30,
                });
            }
            if (self.show_b) {
                _ = try ctx.slider(.{
                    .key = .{ .static = "b" },
                    .label = "B",
                    .value = &self.b,
                    .min = 0,
                    .max = 1,
                    .width = 120,
                    .height = 30,
                });
            }
        }
    };

    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var app = try App.init(std.testing.allocator, &session);
    defer app.deinit();
    var sliders: Sliders = .{};
    try app.mountRoot(Sliders, &sliders);
    const first = try app.frame(1, .{ .width = 200, .height = 200 });
    const b = app.widgetIdForKey(.root, .{ .static = "b" }) orelse
        return error.MissingWidgetIdentity;
    const first_dense = first.tree.frameNode(b) orelse return error.MissingSlider;
    const rect = widget.absoluteRect(first.tree, first_dense);
    _ = try app.handle(.{ .mouse_down = .{
        .button = .left,
        .x = rect.x + rect.w * 0.1,
        .y = rect.y + rect.h / 2,
    } });
    try std.testing.expectEqual(
        b,
        app.focus_manager.captured(first.tree, .{ .mouse = .left }, null).?,
    );

    sliders.show_a = true;
    const second = try app.frame(2, .{ .width = 200, .height = 200 });
    const second_dense = second.tree.frameNode(b) orelse return error.MissingSlider;
    try std.testing.expect(second_dense != first_dense);
    try std.testing.expectEqual(
        b,
        app.focus_manager.captured(second.tree, .{ .mouse = .left }, null).?,
    );
    const second_rect = widget.absoluteRect(second.tree, second_dense);
    _ = try app.handle(.{ .mouse_move = .{
        .x = second_rect.x + second_rect.w * 0.75,
        .y = second_rect.y + second_rect.h / 2,
    } });
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), sliders.b, 0.001);
    try std.testing.expectEqual(@as(f32, 0.2), sliders.a);

    sliders.show_b = false;
    _ = try app.frame(3, .{ .width = 200, .height = 200 });
    try std.testing.expect(app.focus_manager.captured(
        app.tree_ptr.?,
        .{ .mouse = .left },
        null,
    ) == null);
    const a = app.widgetIdForKey(.root, .{ .static = "a" }) orelse
        return error.MissingWidgetIdentity;
    try std.testing.expectEqual(a, app.focus_manager.current.?);
    _ = try app.handle(.{ .mouse_move = .{ .x = 110, .y = 15 } });
    try std.testing.expectEqual(@as(f32, 0.2), sliders.a);
}

test "api-w02 layout and JSON failures preserve the committed state and snapshot" {
    const Root = struct {
        const Self = @This();
        bad_layout: bool = false,
        observed: u32 = 0,

        pub fn draw(self: *Self, ctx: *DrawCtx) !void {
            const state = try ctx.state(u32, "counter", 0);
            state.* += 1;
            self.observed = state.*;
            _ = try ctx.button(.{
                .key = .{ .static = "control" },
                .label = "Control",
                .width = if (self.bad_layout) std.math.nan(f32) else 80,
            });
        }
    };

    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var app = try App.init(std.testing.allocator, &session);
    defer app.deinit();
    var root: Root = .{};
    try app.mountRoot(Root, &root);
    const first = try app.frame(1, .{ .width = 200, .height = 200 });
    const original = app.widgetIdForKey(.root, .{ .static = "control" }) orelse
        return error.MissingWidgetIdentity;
    const state_dir = app.state_prev;
    root.bad_layout = true;
    try std.testing.expectError(
        error.InvalidStyle,
        app.frame(2, .{ .width = 200, .height = 200 }),
    );
    try std.testing.expect(app.tree_ptr == first.tree);
    try std.testing.expect(app.state_prev == state_dir);
    try std.testing.expectEqual(@as(u64, 1), app.frame_generation);

    root.bad_layout = false;
    app.serialize_json = true;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = 0,
    });
    app.gpa = failing.allocator();
    const attempt = app.frame(2, .{ .width = 200, .height = 200 });
    app.gpa = std.testing.allocator;
    try std.testing.expectError(error.WriteFailed, attempt);
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expect(app.tree_ptr == first.tree);
    try std.testing.expect(app.state_prev == state_dir);
    try std.testing.expectEqual(@as(u64, 1), app.frame_generation);
    try std.testing.expectEqual(original, app.widgetIdForKey(
        .root,
        .{ .static = "control" },
    ).?);
    try std.testing.expect(first.tree.frameNode(original) != null);

    app.serialize_json = false;
    const recovered = try app.frame(2, .{ .width = 200, .height = 200 });
    try std.testing.expectEqual(@as(u32, 2), root.observed);
    try std.testing.expect(recovered.prev_tree == first.tree);
    try std.testing.expect(recovered.tree.frameNode(original) != null);
}

test "api-w02 failed layout and publication preserve external scroll state" {
    const Child = struct {
        const Self = @This();
        pub fn draw(_: *Self, _: *DrawCtx) !void {}
    };
    const Root = struct {
        const Self = @This();

        scroll: ScrollState = .{},
        alias_scroll: bool = false,
        add_components: bool = false,
        invalid_layout: bool = false,
        children: [32]Child = @splat(.{}),

        pub fn draw(self: *Self, ctx: *DrawCtx) !void {
            _ = try ctx.column(.{
                .height = .{ .percent = 1 },
                .scroll_state = &self.scroll,
                .scroll_axis = .vertical,
            });
            defer ctx.pop();
            _ = try ctx.spacer(.{ .size = 180, .shrink = 0 });
            if (self.alias_scroll) {
                _ = try ctx.column(.{
                    .display = .none,
                    .scroll_state = &self.scroll,
                });
                ctx.pop();
            }
            if (self.add_components) {
                for (&self.children, 0..) |*child, index| {
                    try ctx.component(Child, .{ .key = .{ .u64 = @intCast(index) } }, child);
                }
            }
            if (self.invalid_layout) {
                _ = try ctx.label(.{ .text = "invalid", .width = std.math.nan(f32) });
            }
        }
    };

    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var app = try App.init(std.testing.allocator, &session);
    defer app.deinit();
    var root: Root = .{};
    try app.mountRoot(Root, &root);
    const first = try app.frame(1, .{ .width = 200, .height = 100 });
    try std.testing.expectEqual([2]f32{ 0, 80 }, root.scroll.max_offset);
    _ = try app.handle(.{ .mouse_wheel = .{
        .x = 10,
        .y = 10,
        .delta_x = 0,
        .delta_y = -2,
    } });
    try std.testing.expectEqual([2]f32{ 0, 40 }, root.scroll.offset);
    _ = try app.handle(.{ .resize = .{ .width = 200, .height = 250 } });

    root.alias_scroll = true;
    app.serialize_json = true;
    var failing_json = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = 0,
    });
    app.gpa = failing_json.allocator();
    const json_attempt = app.handle(.{ .frame = .{ .tick = 2, .time_ms = 10 } });
    app.gpa = std.testing.allocator;
    try std.testing.expectError(error.WriteFailed, json_attempt);
    try std.testing.expect(failing_json.has_induced_failure);
    try std.testing.expect(app.tree_ptr == first.tree);
    try std.testing.expectEqual(@as(u64, 1), app.frame_generation);
    try std.testing.expectEqual([2]f32{ 0, 80 }, root.scroll.max_offset);
    try std.testing.expectEqual([2]f32{ 0, 40 }, root.scroll.offset);
    _ = try app.handle(.{ .mouse_wheel = .{
        .x = 10,
        .y = 10,
        .delta_x = 0,
        .delta_y = -10,
    } });
    try std.testing.expectEqual([2]f32{ 0, 80 }, root.scroll.offset);

    app.serialize_json = false;
    root.add_components = true;
    var failing_registry = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = 0,
    });
    app.gpa = failing_registry.allocator();
    const registry_attempt = app.handle(.{ .frame = .{ .tick = 2, .time_ms = 20 } });
    app.gpa = std.testing.allocator;
    try std.testing.expectError(error.OutOfMemory, registry_attempt);
    try std.testing.expect(failing_registry.has_induced_failure);
    try std.testing.expect(app.tree_ptr == first.tree);
    try std.testing.expectEqual([2]f32{ 0, 80 }, root.scroll.max_offset);
    try std.testing.expectEqual([2]f32{ 0, 80 }, root.scroll.offset);
    _ = try app.handle(.{ .mouse_wheel = .{
        .x = 10,
        .y = 10,
        .delta_x = 0,
        .delta_y = 2,
    } });
    try std.testing.expectEqual([2]f32{ 0, 40 }, root.scroll.offset);

    root.add_components = false;
    root.invalid_layout = true;
    try std.testing.expectError(
        error.InvalidStyle,
        app.handle(.{ .frame = .{ .tick = 2, .time_ms = 30 } }),
    );
    try std.testing.expect(app.tree_ptr == first.tree);
    try std.testing.expectEqual([2]f32{ 0, 80 }, root.scroll.max_offset);
    try std.testing.expectEqual([2]f32{ 0, 40 }, root.scroll.offset);

    root.alias_scroll = false;
    root.invalid_layout = false;
    const recovered = (try app.handle(.{
        .frame = .{ .tick = 2, .time_ms = 40 },
    })) orelse return error.MissingFrameOutput;
    try std.testing.expect(recovered.prev_tree == first.tree);
    try std.testing.expectEqual(@as(u64, 2), app.frame_generation);
    try std.testing.expectEqual([2]f32{ 0, 0 }, root.scroll.max_offset);
    try std.testing.expectEqual([2]f32{ 0, 40 }, root.scroll.offset);
    _ = try app.handle(.{ .mouse_wheel = .{
        .x = 10,
        .y = 10,
        .delta_x = 0,
        .delta_y = -2,
    } });
    try std.testing.expectEqual([2]f32{ 0, 0 }, root.scroll.offset);
}

test "api-w03 failed root replacement preserves GPU mounts and successful retry retires them" {
    const Root = struct {
        const Self = @This();
        clicks: u32 = 0,
        inits: u32 = 0,
        deinits: u32 = 0,
        fail_init: bool = false,

        pub fn draw(_: *Self, ctx: *DrawCtx) !void {
            _ = try ctx.button(.{
                .key = .{ .static = "action" },
                .label = "Action",
                .on_click = Self.onClick,
            });
        }
        fn onClick(self: *Self) void {
            self.clicks += 1;
        }
        pub fn initGpu(self: *Self, _: *GpuEndpoint) !void {
            self.inits += 1;
            if (self.fail_init) return error.NewRootInitFailed;
        }
        pub fn deinitGpu(self: *Self, _: *GpuEndpoint) void {
            self.deinits += 1;
        }
    };

    const Wait = struct {
        var calls: u32 = 0;
        fn complete() void {
            calls += 1;
        }
    };
    Wait.calls = 0;

    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var app = try App.init(std.testing.allocator, &session);
    defer app.deinit();
    var old: Root = .{};
    var candidate: Root = .{ .fail_init = true };
    try app.mountRoot(Root, &old);
    var gpu: noapi.Gpu = undefined;
    var endpoint: GpuEndpoint = .{
        .gpu = &gpu,
        .retirement_wait_for_test = Wait.complete,
    };
    try app.attachGpu(&endpoint);
    const first = try app.frame(1, .{ .width = 120, .height = 100 });
    const action = app.widgetIdForKey(.root, .{ .static = "action" }) orelse
        return error.MissingWidgetIdentity;

    try std.testing.expectError(error.NewRootInitFailed, app.replaceRoot(Root, &candidate));
    try std.testing.expect(app.tree_ptr == first.tree);
    try std.testing.expectEqual(@as(u32, 0), old.deinits);
    try std.testing.expectEqual(@as(u32, 1), candidate.deinits);
    app.activate(first.tree, action);
    try std.testing.expectEqual(@as(u32, 1), old.clicks);
    try std.testing.expectEqual(@as(u32, 0), candidate.clicks);
    try std.testing.expectEqualStrings("Action", firstLabelText(first.tree) orelse
        return error.MissingLabelText);
    try std.testing.expectEqual(@as(u32, 1), Wait.calls);

    candidate.fail_init = false;
    try app.replaceRoot(Root, &candidate);
    try std.testing.expectEqual(@as(u32, 2), candidate.inits);
    try std.testing.expectEqual(@as(u32, 1), old.deinits);
    try std.testing.expectEqual(@as(u32, 1), candidate.deinits);
    try std.testing.expectEqual(@as(u32, 2), Wait.calls);
    app.activate(first.tree, action);
    try std.testing.expectEqual(@as(u32, 1), old.clicks);
    const second = try app.frame(2, .{ .width = 120, .height = 100 });
    try std.testing.expect(second.tree != first.tree);
    try std.testing.expectEqual(@as(u32, 2), candidate.inits);
    app.detachGpu();
    try std.testing.expectEqual(@as(u32, 2), candidate.deinits);
    try std.testing.expectEqual(@as(u32, 3), Wait.calls);
}

test "api-w03 a refused shortcut flush keeps the mounted GPU root live and one retry retires it" {
    const Root = struct {
        const Self = @This();
        clicks: u32 = 0,
        inits: u32 = 0,
        deinits: u32 = 0,

        pub fn draw(_: *Self, ctx: *DrawCtx) !void {
            _ = try ctx.button(.{
                .key = .{ .static = "action" },
                .label = "Action",
                .on_click = Self.onClick,
            });
        }
        fn onClick(self: *Self) void {
            self.clicks += 1;
        }
        pub fn initGpu(self: *Self, _: *GpuEndpoint) !void {
            self.inits += 1;
        }
        pub fn deinitGpu(self: *Self, _: *GpuEndpoint) void {
            self.deinits += 1;
        }
    };

    // A text consumer that only tracks its caret. The replayed arrow key
    // borrows this endpoint after the host released its model.
    const Field = struct {
        const Self = @This();
        const Utf16Range = text_input.Utf16Range;
        const Selection = text_input.Selection;
        const WindowPoint = @import("geometry.zig").WindowPoint;
        caret: usize = 0,

        fn ops() text_input.Ops {
            return text_input.Adapter(Self).ops(.{
                .text = readText,
                .selection = readSelection,
                .marked = readMarked,
                .move = moveCaret,
                .erase = erase,
                .replace = replace,
                .replace_and_mark = replaceMark,
                .unmark = unmark,
                .caret = caretBox,
                .index_at = indexAt,
            });
        }
        fn readText(
            _: std.mem.Allocator,
            _: *const Self,
            _: *anyopaque,
            range: Utf16Range,
            served: *Utf16Range,
        ) anyerror!?[]u8 {
            served.* = range;
            return null;
        }
        fn readSelection(field: *const Self, _: *anyopaque) anyerror!Selection {
            return .{ .range = .{ .start = field.caret, .end = field.caret } };
        }
        fn readMarked(_: *const Self, _: *anyopaque) anyerror!?Utf16Range {
            return null;
        }
        fn moveCaret(field: *Self, _: *anyopaque, request: text_input.Move) anyerror!Selection {
            field.caret = request.offset orelse field.caret;
            return .{ .range = .{ .start = field.caret, .end = field.caret } };
        }
        fn erase(_: *Self, _: *anyopaque, _: text_input.Erase) anyerror!void {
            return error.UnexpectedTextMutation;
        }
        fn replace(_: *Self, _: *anyopaque, _: ?Utf16Range, _: []const u8) anyerror!void {
            return error.UnexpectedTextMutation;
        }
        fn replaceMark(_: *Self, _: *anyopaque, _: ?Utf16Range, _: []const u8, _: ?Utf16Range) anyerror!void {
            return error.UnexpectedTextMutation;
        }
        fn unmark(_: *Self, _: *anyopaque) anyerror!void {
            return error.UnexpectedTextMutation;
        }
        fn caretBox(_: *const Self, _: *anyopaque, range: Utf16Range) anyerror!?text_input.Caret {
            return .{ .area = .{ .x = 8, .y = 0, .w = 0, .h = 18 }, .cursor = @floatFromInt(range.end) };
        }
        fn indexAt(_: *const Self, _: *anyopaque, _: WindowPoint) anyerror!?usize {
            return 0;
        }
    };

    const FakeClock = struct {
        const Self = @This();
        now_ns: i96 = 0,

        fn now(raw: *anyopaque) i96 {
            const self: *Self = @ptrCast(@alignCast(raw));
            return self.now_ns;
        }
        fn clock(self: *Self) Clock {
            return .injected(self, now);
        }
    };
    const Ignore = struct {
        fn replay(_: *anyopaque, _: keymap.Replay) void {}
        fn action(_: *anyopaque, _: keymap.Action) void {}
    };

    const Wait = struct {
        var calls: u32 = 0;
        fn complete() void {
            calls += 1;
        }
    };

    const gpa = std.testing.allocator;
    var session = try Session.init(gpa);
    defer session.deinit() catch unreachable;
    var app = try App.init(gpa, &session);
    defer app.deinit();
    var old: Root = .{};
    var candidate: Root = .{};
    try app.mountRoot(Root, &old);

    var registry = try action_mod.Registry.init(gpa, &session);
    defer registry.deinit();
    var time: FakeClock = .{};
    var shortcuts = try keymap.Keymap.init(gpa, time.clock(), 50);
    defer shortcuts.deinit();
    // A two-stroke chord nothing completes, so one arrow key stays pending in
    // the keymap until a focus change — here, the replacement — flushes it.
    const chord = [_]keymap.Stroke{
        .{ .key = .{ .logical = .{ .named = .left } } },
        .{ .key = .{ .logical = .{ .named = .right } } },
    };
    _ = try shortcuts.add(.{ .sequence = &chord, .action = null }, .{
        .user = &time,
        .on_replay = Ignore.replay,
        .on_action = Ignore.action,
    });

    var field: Field = .{};
    var owned = try session.create(Field, &field);
    var gpu: noapi.Gpu = undefined;
    var endpoint: GpuEndpoint = .{
        .gpu = &gpu,
        .retirement_wait_for_test = Wait.complete,
    };
    try app.attachGpu(&endpoint);
    try app.attachShortcuts(&shortcuts, &registry);
    const first = try app.frame(1, .{ .width = 120, .height = 100 });
    const action = app.widgetIdForKey(.root, .{ .static = "action" }) orelse
        return error.MissingWidgetIdentity;

    _ = app.focus_manager.set(first.tree, action, app.focusObserver());
    app.registerTextEndpoint(.{
        .id = action,
        .owner = owned.weak().erase(),
        .ops = Field.ops(),
        .user = &field,
    });
    _ = try app.handle(.{ .key_down = .{ .key = .left } });
    try std.testing.expectEqual(@as(?i96, 50), app.nextShortcutDeadline());

    // The consumer's model goes away while its endpoint still owns the
    // keyboard, so the replayed key cannot be delivered.
    try session.release(Field, &owned);

    try std.testing.expectError(
        error.EndpointReleased,
        app.replaceRoot(Root, &candidate),
    );
    try std.testing.expect(app.tree_ptr == first.tree);
    try std.testing.expect(first.tree.frameNode(action) != null);
    try std.testing.expectEqual(@as(u32, 1), old.inits);
    try std.testing.expectEqual(@as(u32, 0), old.deinits);
    try std.testing.expectEqual(@as(u32, 1), candidate.inits);
    try std.testing.expectEqual(@as(u32, 1), candidate.deinits);
    try std.testing.expectEqual(@as(u32, 1), Wait.calls);
    app.activate(first.tree, action);
    try std.testing.expectEqual(@as(u32, 1), old.clicks);
    try std.testing.expectEqual(@as(u32, 0), candidate.clicks);

    // The mount the refusal kept is the one the next frame draws, so its GPU
    // resources were neither released nor initialized a second time.
    const second = try app.frame(2, .{ .width = 120, .height = 100 });
    try std.testing.expect(second.tree != first.tree);
    try std.testing.expectEqual(@as(u32, 1), old.inits);
    try std.testing.expectEqual(@as(u32, 0), old.deinits);
    try std.testing.expectEqual(@as(u32, 1), candidate.inits);
    try std.testing.expectEqual(@as(u32, 1), Wait.calls);

    try app.replaceRoot(Root, &candidate);
    try std.testing.expectEqual(@as(u32, 2), candidate.inits);
    try std.testing.expectEqual(@as(u32, 1), old.deinits);
    try std.testing.expectEqual(@as(u32, 1), candidate.deinits);
    try std.testing.expectEqual(@as(u32, 2), Wait.calls);
    app.detachGpu();
    try std.testing.expectEqual(@as(u32, 2), candidate.deinits);
    try std.testing.expectEqual(@as(u32, 3), Wait.calls);
}

test "api-w03 successful replacement revokes old callbacks and resets transient state" {
    const Root = struct {
        const Self = @This();
        clicks: u32 = 0,
        observed: u32 = 0,

        pub fn draw(self: *Self, ctx: *DrawCtx) !void {
            const state = try ctx.state(u32, "count", 0);
            state.* += 1;
            self.observed = state.*;
            _ = try ctx.button(.{
                .key = .{ .static = "action" },
                .label = "Action",
                .on_click = Self.onClick,
            });
        }
        fn onClick(self: *Self) void {
            self.clicks += 1;
        }
    };

    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var app = try App.init(std.testing.allocator, &session);
    defer app.deinit();
    var old: Root = .{};
    var replacement: Root = .{};
    try app.mountRoot(Root, &old);
    const first = try app.frame(1, .{ .width = 120, .height = 100 });
    const old_id = app.widgetIdForKey(.root, .{ .static = "action" }) orelse
        return error.MissingWidgetIdentity;
    const dense = first.tree.frameNode(old_id) orelse return error.MissingButton;
    const rect = widget.absoluteRect(first.tree, dense);
    _ = try app.handle(.{ .mouse_down = .{
        .button = .left,
        .x = rect.x + rect.w / 2,
        .y = rect.y + rect.h / 2,
    } });
    try std.testing.expectEqual(@as(u32, 0), old.clicks);
    try std.testing.expect(app.focus_manager.current != null);
    try std.testing.expect(app.pressed != null);

    try app.replaceRoot(Root, &replacement);
    try std.testing.expect(app.tree_ptr == null);
    try std.testing.expect(app.state_prev == null);
    try std.testing.expect(app.focus_manager.current == null);
    try std.testing.expect(app.pressed == null);
    try std.testing.expect(app.widgetIdForKey(.root, .{ .static = "action" }) == null);
    try std.testing.expect(first.tree.frameNode(old_id) != null);
    app.activate(first.tree, old_id);
    _ = try app.handle(.{ .mouse_down = .{
        .button = .left,
        .x = rect.x + rect.w / 2,
        .y = rect.y + rect.h / 2,
    } });
    try std.testing.expectEqual(@as(u32, 0), old.clicks);

    const second = try app.frame(2, .{ .width = 120, .height = 100 });
    const new_id = app.widgetIdForKey(.root, .{ .static = "action" }) orelse
        return error.MissingWidgetIdentity;
    try std.testing.expect(!old_id.eql(new_id));
    try std.testing.expectEqual(@as(u32, 1), replacement.observed);
    try std.testing.expectEqual(@as(?*const WidgetTree, null), second.prev_tree);
    try std.testing.expect(first.tree.frameNode(old_id) != null);
    app.activate(second.tree, old_id);
    try std.testing.expectEqual(@as(u32, 0), replacement.clicks);
    app.activate(second.tree, new_id);
    try std.testing.expectEqual(@as(u32, 1), replacement.clicks);
}

test "api-w03 model view draws with a scoped borrow and callbacks target the view" {
    const Shared = struct { value: u32 };
    const View = struct {
        clicks: u32 = 0,
        draws: u32 = 0,
        const Self = @This();

        pub fn draw(self: *Self, model: *const Shared, ctx: *DrawCtx) !void {
            self.draws += 1;
            const model_context = ctx.context orelse return error.MissingModelContext;
            const weak = try model_context.root(Shared);
            try std.testing.expectError(
                error.DrawMutationForbidden,
                model_context.session.update(Shared, weak, {}, struct {
                    fn update(_: *Shared, _: void) !void {}
                }.update),
            );
            const frame = ctx.frame_info orelse return error.MissingFrameInfo;
            const text = try std.fmt.allocPrint(
                ctx.arena,
                "{d}/{d}/{d}/{d}",
                .{
                    model.value,
                    frame.tick,
                    frame.generation,
                    @as(u32, @intFromFloat(frame.surface.width)),
                },
            );
            _ = try ctx.label(.{ .text = text });
            _ = try ctx.button(.{
                .key = .{ .static = "action" },
                .label = "Action",
                .on_click = Self.onClick,
            });
        }
        fn onClick(self: *Self) void {
            self.clicks += 1;
        }
    };
    const Local = struct {
        const Self = @This();
        pub fn draw(_: *Self, _: *DrawCtx) !void {}
    };
    const Probe = struct {
        app: *App,
        replacement: *Local,
        committed_tree: *const WidgetTree,
    };

    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var value: Shared = .{ .value = 7 };
    var owner = try session.create(Shared, &value);
    defer if (owner.ticket != 0) session.release(Shared, &owner) catch unreachable;
    const weak = owner.weak();
    var app = try App.init(std.testing.allocator, &session);
    var app_live = true;
    errdefer if (app_live) app.deinit();
    var view: View = .{};
    try app.mountModelRoot(Shared, View, owner, &view);
    try session.release(Shared, &owner);
    const first = try app.frame(1, .{ .width = 120, .height = 100 });
    try std.testing.expectEqualStrings("7/1/1/120", firstLabelText(first.tree) orelse
        return error.MissingLabelText);
    const action = app.widgetIdForKey(.root, .{ .static = "action" }) orelse
        return error.MissingWidgetIdentity;
    app.activate(first.tree, action);
    try std.testing.expectEqual(@as(u32, 1), view.clicks);
    var replacement: Local = .{};
    var probe: Probe = .{
        .app = &app,
        .replacement = &replacement,
        .committed_tree = first.tree,
    };
    try session.read(Shared, weak, &probe, struct {
        fn check(_: *const Shared, state: *Probe) !void {
            try std.testing.expectError(
                error.ConflictingAccess,
                state.app.replaceRoot(Local, state.replacement),
            );
            try std.testing.expect(state.app.tree_ptr == state.committed_tree);
        }
    }.check);
    app.activate(first.tree, action);
    try std.testing.expectEqual(@as(u32, 2), view.clicks);
    try session.update(Shared, weak, {}, struct {
        fn update(model: *Shared, _: void) !void {
            model.value = 9;
        }
    }.update);
    const second = try app.frame(2, .{ .width = 120, .height = 100 });
    try std.testing.expectEqualStrings("9/2/2/120", firstLabelText(second.tree) orelse
        return error.MissingLabelText);
    try std.testing.expectEqual(@as(u32, 2), view.draws);
    try std.testing.expectEqualStrings("7/1/1/120", firstLabelText(first.tree) orelse
        return error.MissingLabelText);
    app.deinit();
    app_live = false;
    try std.testing.expect((try session.upgrade(Shared, weak)) == null);
}

test "api-w03 current root hooks follow replacement during a click" {
    const Root = struct {
        const Self = @This();

        app: *App,
        replacement: ?*Self = null,
        events: u32 = 0,
        frames: u32 = 0,
        last_frame_ms: u64 = 0,
        precision_keys: u32 = 0,
        clicks: u32 = 0,
        slider: f32 = 0.5,

        pub fn draw(self: *Self, ctx: *DrawCtx) !void {
            _ = try ctx.column(.{});
            defer ctx.pop();
            _ = try ctx.slider(.{
                .key = .{ .static = "slider" },
                .label = "Slide",
                .value = &self.slider,
                .min = 0,
                .max = 1,
            });
            _ = try ctx.button(.{
                .key = .{ .static = "button" },
                .label = "Replace",
                .on_click = Self.onClick,
            });
        }

        fn onClick(self: *Self) void {
            self.clicks += 1;
            if (self.replacement) |next| {
                self.app.replaceRoot(Self, next) catch @panic("root replacement failed");
            }
        }

        pub fn onRoutedEvent(self: *Self, context: *event.DispatchContext) void {
            if (context.phase != .target) return;
            if (context.current_target != context.target) return;
            switch (context.event.*) {
                .mouse_move => self.events += 1,
                else => {},
            }
        }

        pub fn onFrame(self: *Self, time_ms: u64) void {
            self.frames += 1;
            self.last_frame_ms = time_ms;
        }

        pub fn onPrecisionKey(self: *Self) void {
            self.precision_keys += 1;
        }
    };

    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var app = try App.init(std.testing.allocator, &session);
    defer app.deinit();
    var next: Root = .{ .app = &app };
    var old: Root = .{ .app = &app, .replacement = &next };
    try app.mountRoot(Root, &old);
    try std.testing.expect(app.currentRootMatches(Root, &old));
    app.dispatchRootFrame(11);
    try std.testing.expect(app.dispatchRootPrecisionKey());
    const first = try app.frame(1, .{ .width = 200, .height = 200 });
    const slider_id = app.widgetIdForKey(.root, .{ .static = "slider" }) orelse
        return error.MissingWidgetIdentity;
    const button_id = app.widgetIdForKey(.root, .{ .static = "button" }) orelse
        return error.MissingWidgetIdentity;
    const slider_dense = first.tree.frameNode(slider_id) orelse return error.MissingSlider;
    const button_dense = first.tree.frameNode(button_id) orelse return error.MissingButton;
    const slider_rect = widget.absoluteRect(first.tree, slider_dense);
    const button_rect = widget.absoluteRect(first.tree, button_dense);
    // Routed input follows the committed tree, so the old root sees the move
    // only once a frame has published one.
    _ = try app.handle(.{ .mouse_move = .{
        .x = slider_rect.x + slider_rect.w / 2,
        .y = slider_rect.y + slider_rect.h / 2,
    } });
    _ = try app.handle(.{ .mouse_down = .{
        .button = .left,
        .x = slider_rect.x + slider_rect.w / 2,
        .y = slider_rect.y + slider_rect.h / 2,
    } });
    try std.testing.expectEqual(
        slider_id,
        app.focus_manager.captured(first.tree, .{ .mouse = .left }, null) orelse
            return error.MissingSliderCapture,
    );
    _ = try app.handle(.{ .mouse_up = .{
        .button = .left,
        .x = slider_rect.x + slider_rect.w / 2,
        .y = slider_rect.y + slider_rect.h / 2,
    } });

    // The old activation callback replaces the root during mouse-up.
    _ = try app.handle(.{ .mouse_down = .{
        .button = .left,
        .x = button_rect.x + button_rect.w / 2,
        .y = button_rect.y + button_rect.h / 2,
    } });
    try std.testing.expectEqual(@as(u32, 0), old.clicks);
    _ = try app.handle(.{ .mouse_up = .{
        .button = .left,
        .x = button_rect.x + button_rect.w / 2,
        .y = button_rect.y + button_rect.h / 2,
    } });
    try std.testing.expectEqual(@as(u32, 1), old.clicks);
    try std.testing.expect(app.currentRootMatches(Root, &next));
    try std.testing.expect(!app.currentRootMatches(Root, &old));
    try std.testing.expect(app.tree_ptr == null);
    try std.testing.expect(app.focus_manager.current == null);
    try std.testing.expect(app.pressed == null);
    try std.testing.expect(first.tree.frameNode(button_id) != null);
    app.activate(first.tree, button_id);
    try std.testing.expectEqual(@as(u32, 1), old.clicks);

    const second = try app.frame(2, .{ .width = 200, .height = 200 });
    try std.testing.expect(second.prev_tree == null);
    try std.testing.expect(first.tree.frameNode(button_id) != null);
    app.dispatchRootFrame(29);
    try std.testing.expect(app.dispatchRootPrecisionKey());
    // The replacement root is the one the next routed event reaches, and the
    // retired root never sees it again.
    _ = try app.handle(.{ .mouse_move = .{
        .x = button_rect.x + button_rect.w / 2,
        .y = button_rect.y + button_rect.h / 2,
    } });
    try std.testing.expectEqual(@as(u32, 1), old.events);
    try std.testing.expectEqual(@as(u32, 1), old.frames);
    try std.testing.expectEqual(@as(u64, 11), old.last_frame_ms);
    try std.testing.expectEqual(@as(u32, 1), old.precision_keys);
    try std.testing.expectEqual(@as(u32, 1), next.events);
    try std.testing.expectEqual(@as(u32, 1), next.frames);
    try std.testing.expectEqual(@as(u64, 29), next.last_frame_ms);
    try std.testing.expectEqual(@as(u32, 1), next.precision_keys);
}

test "api-w09 one component sees one delivery per phase on the node it owns" {
    const Visit = struct { node: FrameNodeId, phase: event.Phase };
    const Child = struct {
        const Self = @This();
        // SAFETY: onRoutedEvent writes every visit before advancing count.
        visits: [8]Visit = undefined,
        count: u8 = 0,
        outer: FrameNodeId = .root,
        inner: FrameNodeId = .root,
        button: FrameNodeId = .root,
        label: FrameNodeId = .root,

        pub fn draw(self: *Self, ctx: *DrawCtx) !void {
            self.outer = try ctx.column(.{});
            defer ctx.pop();
            self.inner = try ctx.column(.{});
            defer ctx.pop();
            self.button = try ctx.button(.{
                .key = .{ .static = "child" },
                .label = "child",
            });
            self.label = ctx.tree.node(self.button).?.children.items[0];
        }

        pub fn onRoutedEvent(self: *Self, context: *event.DispatchContext) void {
            if (self.count >= self.visits.len) return;
            self.visits[self.count] = .{
                .node = context.current_target,
                .phase = context.phase,
            };
            self.count += 1;
        }
    };
    const Root = struct {
        const Self = @This();
        child: *Child,
        column: FrameNodeId = .root,
        // SAFETY: onRoutedEvent writes every visit before advancing count.
        visits: [8]Visit = undefined,
        count: u8 = 0,

        pub fn draw(self: *Self, ctx: *DrawCtx) !void {
            self.column = try ctx.column(.{});
            defer ctx.pop();
            try ctx.component(Child, .{ .key = .{ .static = "child" } }, self.child);
        }

        pub fn onRoutedEvent(self: *Self, context: *event.DispatchContext) void {
            if (self.count >= self.visits.len) return;
            self.visits[self.count] = .{
                .node = context.current_target,
                .phase = context.phase,
            };
            self.count += 1;
        }
    };

    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var app = try App.init(std.testing.allocator, &session);
    defer app.deinit();
    var child: Child = .{};
    var root: Root = .{ .child = &child };
    try app.mountRoot(Root, &root);
    const frame = try app.frame(1, .{ .width = 200, .height = 200 });
    try std.testing.expect(child.label != child.button);
    const rect = widget.absoluteRect(frame.tree, child.label);
    _ = try app.handle(.{ .mouse_move = .{
        .x = rect.x + rect.w / 2,
        .y = rect.y + rect.h / 2,
    } });

    // The child owns every node of its own path. Capture delivers once, at
    // the outermost node it owns; the target delivers at the node the event
    // names; bubble delivers once, at the innermost node it owns. The root
    // owns one path node and sees the capture and the bubble of it.
    try std.testing.expectEqual(@as(u8, 3), child.count);
    try std.testing.expectEqual(child.outer, child.visits[0].node);
    try std.testing.expectEqual(event.Phase.capture, child.visits[0].phase);
    try std.testing.expectEqual(child.label, child.visits[1].node);
    try std.testing.expectEqual(event.Phase.target, child.visits[1].phase);
    try std.testing.expectEqual(child.button, child.visits[2].node);
    try std.testing.expectEqual(event.Phase.bubble, child.visits[2].phase);

    try std.testing.expectEqual(@as(u8, 2), root.count);
    try std.testing.expectEqual(root.column, root.visits[0].node);
    try std.testing.expectEqual(event.Phase.capture, root.visits[0].phase);
    try std.testing.expectEqual(root.column, root.visits[1].node);
    try std.testing.expectEqual(event.Phase.bubble, root.visits[1].phase);
}

test "api-w09 leave, cancel and focus loss reach the pointer owner" {
    const Kind = enum {
        mouse_move,
        mouse_leave,
        mouse_down,
        mouse_cancel,
        capture_lost,
        window_focus_lost,
    };
    const Record = struct { kind: Kind, node: FrameNodeId };
    const Root = struct {
        const Self = @This();
        // SAFETY: onRoutedEvent writes every record before advancing count.
        records: [16]Record = undefined,
        count: u8 = 0,
        button: FrameNodeId = .root,
        label: FrameNodeId = .root,

        pub fn draw(self: *Self, ctx: *DrawCtx) !void {
            _ = try ctx.column(.{});
            defer ctx.pop();
            self.button = try ctx.button(.{
                .key = .{ .static = "target" },
                .label = "target",
            });
            self.label = ctx.tree.node(self.button).?.children.items[0];
        }

        pub fn onRoutedEvent(self: *Self, context: *event.DispatchContext) void {
            // One record per event: the capture and bubble walks reach this
            // component again through the container it drew, and those are
            // the same event, not a second one.
            if (context.phase != .target) return;
            const kind: Kind = switch (context.event.*) {
                .mouse_move => .mouse_move,
                .mouse_leave => .mouse_leave,
                .mouse_down => .mouse_down,
                .mouse_cancel => .mouse_cancel,
                .capture_lost => .capture_lost,
                .window_focus_lost => .window_focus_lost,
                else => return,
            };
            if (self.count >= self.records.len) return;
            self.records[self.count] = .{ .kind = kind, .node = context.current_target };
            self.count += 1;
        }
    };

    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var app = try App.init(std.testing.allocator, &session);
    defer app.deinit();
    var root: Root = .{};
    try app.mountRoot(Root, &root);
    const frame = try app.frame(1, .{ .width = 200, .height = 200 });
    const rect = widget.absoluteRect(frame.tree, root.label);
    const point = [2]f32{ rect.x + rect.w / 2, rect.y + rect.h / 2 };
    try std.testing.expect(root.label != root.button);

    _ = try app.handle(.{ .mouse_move = .{ .x = point[0], .y = point[1] } });
    _ = try app.handle(.mouse_leave);
    // Leaving clears hover and does not release a capture taken in-window.
    try std.testing.expect(app.mouse_pos == null);
    try std.testing.expect(app.focus_manager.captured(frame.tree, .{ .mouse = .left }, null) == null);

    _ = try app.handle(.{ .mouse_down = .{ .button = .left, .x = point[0], .y = point[1] } });
    const captured = app.focus_manager.captured(frame.tree, .{ .mouse = .left }, null) orelse
        return error.MissingCapture;
    try std.testing.expect(captured.eql(app.widgetIdForKey(.root, .{ .static = "target" }).?));
    _ = try app.handle(.{ .mouse_cancel = .{ .button = .left, .x = point[0], .y = point[1] } });
    try std.testing.expect(app.focus_manager.captured(frame.tree, .{ .mouse = .left }, null) == null);

    _ = try app.handle(.{ .mouse_move = .{ .x = point[0], .y = point[1] } });
    _ = try app.handle(.{ .mouse_down = .{ .button = .left, .x = point[0], .y = point[1] } });
    _ = try app.handle(.window_focus_lost);
    try std.testing.expect(app.focus_manager.captured(frame.tree, .{ .mouse = .left }, null) == null);
    try std.testing.expect(app.mouse_pos == null);

    // A cancel is itself the one revocation its owner sees, and a focus loss
    // reaches the hovered node and then the node that held the capture.
    const expected = [_]Record{
        .{ .kind = .mouse_move, .node = root.label },
        .{ .kind = .mouse_leave, .node = root.label },
        .{ .kind = .mouse_down, .node = root.label },
        .{ .kind = .mouse_cancel, .node = root.button },
        .{ .kind = .mouse_move, .node = root.label },
        .{ .kind = .mouse_down, .node = root.label },
        .{ .kind = .window_focus_lost, .node = root.label },
        .{ .kind = .capture_lost, .node = root.button },
    };
    try std.testing.expectEqual(expected.len, @as(usize, root.count));
    for (expected, 0..) |want, index| {
        try std.testing.expectEqual(want.kind, root.records[index].kind);
        try std.testing.expectEqual(want.node, root.records[index].node);
    }
}

test "api-w03 borrowed old or candidate models cannot retire the committed GPU root" {
    const Shared = struct { value: u32 };
    const View = struct {
        const Self = @This();
        starts: *u32,
        stops: *u32,

        pub fn draw(_: *Self, value: *const Shared, ctx: *DrawCtx) !void {
            const label = try std.fmt.allocPrint(ctx.arena, "value: {d}", .{value.value});
            _ = try ctx.label(.{ .text = label });
        }

        pub fn initGpu(self: *Self, _: *GpuEndpoint) !void {
            self.starts.* += 1;
        }

        pub fn deinitGpu(self: *Self, _: *GpuEndpoint) void {
            self.stops.* += 1;
        }
    };
    const Probe = struct {
        app: *App,
        candidate: Model(Shared),
        view: *View,
        const Self = @This();

        fn duringUpdate(_: *Shared, self: *Self) !void {
            try std.testing.expectError(
                error.ConflictingAccess,
                self.app.replaceModelRoot(Shared, View, self.candidate, self.view),
            );
        }
    };
    const Wait = struct {
        fn complete() void {}
    };

    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var old_value: Shared = .{ .value = 2 };
    var old_owner = try session.create(Shared, &old_value);
    defer session.release(Shared, &old_owner) catch unreachable;
    var candidate_value: Shared = .{ .value = 3 };
    var candidate_owner = try session.create(Shared, &candidate_value);
    defer session.release(Shared, &candidate_owner) catch unreachable;
    var app = try App.init(std.testing.allocator, &session);
    defer app.deinit();
    var old_starts: u32 = 0;
    var old_stops: u32 = 0;
    var next_starts: u32 = 0;
    var next_stops: u32 = 0;
    var old_view: View = .{ .starts = &old_starts, .stops = &old_stops };
    var next_view: View = .{ .starts = &next_starts, .stops = &next_stops };
    try app.mountModelRoot(Shared, View, old_owner, &old_view);
    var gpu: noapi.Gpu = undefined;
    var endpoint: GpuEndpoint = .{ .gpu = &gpu, .retirement_wait_for_test = Wait.complete };
    try app.attachGpu(&endpoint);
    const first = try app.frame(1, .{ .width = 120, .height = 100 });
    var probe: Probe = .{ .app = &app, .candidate = candidate_owner, .view = &next_view };
    try session.update(Shared, old_owner, &probe, Probe.duringUpdate);
    try session.update(Shared, candidate_owner, &probe, Probe.duringUpdate);
    try std.testing.expect(app.tree_ptr == first.tree);
    try std.testing.expectEqual(@as(u32, 1), old_starts);
    try std.testing.expectEqual(@as(u32, 0), old_stops);
    try std.testing.expectEqual(@as(u32, 0), next_starts);
    try std.testing.expectEqual(@as(u32, 0), next_stops);
    const second = try app.frame(2, .{ .width = 120, .height = 100 });
    try std.testing.expectEqualStrings(
        "value: 2",
        firstLabelText(second.tree) orelse return error.MissingLabelText,
    );
    app.detachGpu();
    try std.testing.expectEqual(@as(u32, 1), old_stops);
    try std.testing.expectEqual(@as(u32, 0), next_stops);
}

test "api-w08 hidden ancestor clears focus and rejects direct activation" {
    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var app = try App.init(std.testing.allocator, &session);
    defer app.deinit();

    const Root = struct {
        const Self = @This();
        hide: bool = false,
        inside_clicks: u32 = 0,
        outside_clicks: u32 = 0,

        fn inside(self: *Self) void {
            self.inside_clicks += 1;
        }
        fn outside(self: *Self) void {
            self.outside_clicks += 1;
        }
        pub fn draw(self: *Self, ctx: *DrawCtx) !void {
            _ = try ctx.column(.{
                .visibility = if (self.hide) Visibility.hidden else Visibility.visible,
            });
            _ = try ctx.button(.{
                .key = .{ .static = "inside" },
                .label = "inside",
                .on_click = Self.inside,
            });
            ctx.pop();
            _ = try ctx.button(.{
                .key = .{ .static = "outside" },
                .label = "outside",
                .on_click = Self.outside,
            });
        }
    };

    var root: Root = .{};
    try app.mountRoot(Root, &root);
    _ = try app.frame(1, .{ .width = 200, .height = 100 });
    const inside = app.widgetIdForKey(.root, .{ .static = "inside" }) orelse
        return error.MissingWidgetIdentity;
    const outside = app.widgetIdForKey(.root, .{ .static = "outside" }) orelse
        return error.MissingWidgetIdentity;
    _ = try app.handle(.{ .key_down = .{ .key = .tab, .shift = false } });
    try std.testing.expectEqual(inside, app.focus_manager.current.?);

    root.hide = true;
    const hidden_frame = try app.frame(2, .{ .width = 200, .height = 100 });
    try std.testing.expectEqual(outside, app.focus_manager.current.?);
    try std.testing.expect(hidden_frame.tree.frameNode(inside) != null);
    app.activate(hidden_frame.tree, inside);
    try std.testing.expectEqual(@as(u32, 0), root.inside_clicks);
    _ = try app.handle(.{ .key_down = .{ .key = .tab, .shift = false } });
    try std.testing.expectEqual(outside, app.focus_manager.current.?);
    app.activate(hidden_frame.tree, outside);
    try std.testing.expectEqual(@as(u32, 1), root.outside_clicks);
}

test "api-w04 committed model reads dirty both views and failed builds keep dependencies" {
    const Shared = struct { count: u32 = 1 };
    const View = struct {
        const Self = @This();
        observed: u32 = 0,
        fail_after_read: bool = false,

        pub fn draw(self: *Self, value: *const Shared, ctx: *DrawCtx) !void {
            self.observed = value.count;
            if (self.fail_after_read) return error.IntentionalFrameFailure;
            const text = try std.fmt.allocPrint(ctx.arena, "{d}", .{value.count});
            _ = try ctx.label(.{ .text = text });
        }
    };
    const Update = struct {
        fn increase(value: *Shared, _: void) !void {
            value.count += 1;
        }
    };
    const Plain = struct {
        const Self = @This();
        pub fn draw(_: *Self, ctx: *DrawCtx) !void {
            _ = try ctx.label(.{ .text = "replacement" });
        }
    };

    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var initial: Shared = .{};
    var owner = try session.create(Shared, &initial);
    defer session.release(Shared, &owner) catch unreachable;
    var left = try App.init(std.testing.allocator, &session);
    defer left.deinit();
    var right = try App.init(std.testing.allocator, &session);
    defer right.deinit();
    var left_view: View = .{};
    var right_view: View = .{};
    try left.mountModelRoot(Shared, View, owner, &left_view);
    try right.mountModelRoot(Shared, View, owner, &right_view);
    try std.testing.expect(try session.takeRedraw(left.window));
    try std.testing.expect(try session.takeRedraw(right.window));
    _ = try left.frame(1, .{ .width = 160, .height = 80 });
    _ = try right.frame(1, .{ .width = 160, .height = 80 });
    try std.testing.expectEqual(@as(u32, 1), left_view.observed);
    try std.testing.expectEqual(@as(u32, 1), right_view.observed);
    try std.testing.expect(!try session.takeRedraw(left.window));
    try std.testing.expect(!try session.takeRedraw(right.window));

    try session.update(Shared, owner, {}, Update.increase);
    try std.testing.expect(try session.takeRedraw(left.window));
    try std.testing.expect(try session.takeRedraw(right.window));
    try std.testing.expect(!try session.takeRedraw(left.window));
    try std.testing.expect(!try session.takeRedraw(right.window));
    _ = try right.frame(2, .{ .width = 160, .height = 80 });
    try std.testing.expectEqual(@as(u32, 2), right_view.observed);

    left_view.fail_after_read = true;
    try std.testing.expectError(
        error.IntentionalFrameFailure,
        left.frame(2, .{ .width = 160, .height = 80 }),
    );
    try std.testing.expect(try session.takeRedraw(left.window));
    left_view.fail_after_read = false;
    _ = try left.frame(2, .{ .width = 160, .height = 80 });
    try std.testing.expectEqual(@as(u32, 2), left_view.observed);
    try session.update(Shared, owner, {}, Update.increase);
    try std.testing.expect(try session.takeRedraw(left.window));
    try std.testing.expect(try session.takeRedraw(right.window));
    _ = try left.frame(3, .{ .width = 160, .height = 80 });
    _ = try right.frame(3, .{ .width = 160, .height = 80 });
    try std.testing.expectEqual(@as(u32, 3), left_view.observed);
    try std.testing.expectEqual(@as(u32, 3), right_view.observed);
    var plain: Plain = .{};
    try right.replaceRoot(Plain, &plain);
    try std.testing.expect(try session.takeRedraw(right.window));
    _ = try right.frame(4, .{ .width = 160, .height = 80 });
    try session.update(Shared, owner, {}, Update.increase);
    try std.testing.expect(try session.takeRedraw(left.window));
    try std.testing.expect(!try session.takeRedraw(right.window));
}

test "api-w04 self-unsubscribing observer defers a second update across two views" {
    const Shared = struct { count: u32 = 0 };
    const View = struct {
        const Self = @This();
        observed: *u32,

        pub fn draw(self: *Self, value: *const Shared, ctx: *DrawCtx) !void {
            self.observed.* = value.count;
            _ = try ctx.label(.{ .text = "shared" });
        }
    };
    const Deferred = struct {};
    const Update = struct {
        fn bump(value: *Shared, _: void) !void {
            value.count += 1;
        }
    };
    const Observer = struct {
        const Self = @This();
        token: *Token,
        weak_self: *model_type.WeakModel(Self),
        source: model_type.WeakModel(Shared),
        left: *App,
        deliveries: *u32,

        fn changed(self: *const Self, _: model_type.WeakModel(Shared), session: *Session) void {
            self.deliveries.* += 1;
            if (!session.unsubscribe(self.token)) @panic("observer token already cancelled");
            std.testing.expectError(
                error.TransactionInProgress,
                self.left.frame(99, .{ .width = 120, .height = 80 }),
            ) catch @panic("observer entered a partial frame");
            var payload: Deferred = .{};
            session.deferOwned(Deferred, Self, self.weak_self.*, &payload, Self.apply) catch
                @panic("deferred model update failed");
        }

        fn apply(self: *const Self, _: *Deferred, session: *Session) void {
            session.update(Shared, self.source, {}, Update.bump) catch
                @panic("deferred model update failed");
        }
    };

    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var initial: Shared = .{};
    var model = try session.create(Shared, &initial);
    defer session.release(Shared, &model) catch unreachable;
    var left = try App.init(std.testing.allocator, &session);
    defer left.deinit();
    var right = try App.init(std.testing.allocator, &session);
    defer right.deinit();
    var left_count: u32 = 0;
    var right_count: u32 = 0;
    var left_view: View = .{ .observed = &left_count };
    var right_view: View = .{ .observed = &right_count };
    try left.mountModelRoot(Shared, View, model, &left_view);
    try right.mountModelRoot(Shared, View, model, &right_view);
    _ = try left.frame(1, .{ .width = 120, .height = 80 });
    _ = try right.frame(1, .{ .width = 120, .height = 80 });
    _ = try session.takeRedraw(left.window);
    _ = try session.takeRedraw(right.window);
    var token: Token = .{};
    var weak_observer: model_type.WeakModel(Observer) = undefined;
    var deliveries: u32 = 0;
    var observer_value: Observer = .{
        .token = &token,
        .weak_self = &weak_observer,
        .source = model.weak(),
        .left = &left,
        .deliveries = &deliveries,
    };
    var observer = try session.create(Observer, &observer_value);
    defer session.release(Observer, &observer) catch unreachable;
    weak_observer = observer.weak();
    token = try session.observe(Shared, Observer, model.weak(), weak_observer, Observer.changed);

    try session.update(Shared, model, {}, Update.bump);
    try std.testing.expectEqual(@as(u32, 1), deliveries);
    try std.testing.expect(try session.takeRedraw(left.window));
    try std.testing.expect(try session.takeRedraw(right.window));
    try std.testing.expect(!try session.takeRedraw(left.window));
    try std.testing.expect(!try session.takeRedraw(right.window));
    _ = try left.frame(2, .{ .width = 120, .height = 80 });
    _ = try right.frame(2, .{ .width = 120, .height = 80 });
    try std.testing.expectEqual(@as(u32, 2), left_count);
    try std.testing.expectEqual(@as(u32, 2), right_count);
}

// --- paint band publication ----------------------------------------------

/// A custom leaf whose single paint record asks for an enormous layer, so a
/// frame can be failed on a layer that cannot be represented.
const LayerBumpElement = struct {
    bump: u32,

    pub fn measure(_: *const LayerBumpElement, measure_input: element.MeasureInput) element.Error!widget.Size {
        return .{
            .width = measure_input.known_dimensions.width orelse 20,
            .height = measure_input.known_dimensions.height orelse 10,
        };
    }

    pub const PhaseState = struct {};

    pub fn paint(
        self: *const LayerBumpElement,
        _: *PhaseState,
        geometry: element.Geometry,
        canvas: *element.PaintWriter,
    ) element.Error!void {
        try canvas.addRect(.{
            .bounds = .{ .x = 0, .y = 0, .w = geometry.content.w, .h = geometry.content.h },
            .fill = .{ .solid = .{ .srgb = .{ .r = 0.1, .g = 0.1, .b = 0.1 } } },
            .layer = self.bump,
        });
    }
};

/// A root that draws one custom leaf with the requested record bump, and
/// counts the GPU frames its own hook was dispatched for.
const LayerBumpRoot = struct {
    bump: u32 = 0,
    authored: u32 = 0,
    gpu_frames: u32 = 0,

    pub fn initGpu(_: *LayerBumpRoot, _: *GpuEndpoint) anyerror!void {}

    pub fn frameGpu(self: *LayerBumpRoot, _: *GpuFrame) anyerror!void {
        self.gpu_frames += 1;
    }

    pub fn draw(self: *LayerBumpRoot, ctx: *DrawCtx) !void {
        _ = try ctx.elementLeaf(LayerBumpElement, .{ .bump = self.bump }, .{
            .layer = self.authored,
            .width = 20,
            .height = 10,
        });
    }
};

fn cpuGpuWait() void {}

/// A failed frame cancels the recording it was building, so a GPU test hands
/// the App a real cancellation rather than an idle frame.
fn discardRecording(_: *anyopaque, _: *noapi.CommandBuffer) anyerror!void {}

// A custom layer bump that cannot be represented fails the frame BEFORE
// publication, with no overlay frame attached at all. The App is the only
// thing validating it there, so this is the path that would otherwise let an
// overflowing layer reach the published tree unbanded.
test "App: an overflowing custom layer bump fails publication with no overlay attached" {
    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var app = try App.init(std.testing.allocator, &session);
    defer app.deinit();
    var root: LayerBumpRoot = .{ .authored = 4, .bump = std.math.maxInt(u32) };
    try app.mountRoot(LayerBumpRoot, &root);
    try std.testing.expectEqual(@as(?*const WidgetTree, null), app.tree_ptr);

    try std.testing.expectError(
        error.PaintLayerOverflow,
        app.frame(1, .{ .width = 200, .height = 200 }),
    );
    // Nothing was published, so no tree carries the unrepresentable layer.
    try std.testing.expectEqual(@as(?*const WidgetTree, null), app.tree_ptr);
    try std.testing.expectEqual(@as(u32, 0), app.frame_generation);

    // The same root without the overflow publishes normally.
    root.bump = 2;
    const out = try app.frame(1, .{ .width = 200, .height = 200 });
    defer if (out.json) |json| std.testing.allocator.free(json);
    var saw_element: usize = 0;
    for (out.tree.nodes.items) |node| {
        if (node.kind != .element) continue;
        saw_element += 1;
        try std.testing.expectEqual(@as(u32, 6), try widget.effectiveLayer(&node, 2));
    }
    try std.testing.expectEqual(@as(usize, 1), saw_element);
}

// A failed band resolution keeps the previous publication intact and never
// reaches component GPU dispatch: the bands resolve before any GPU record is
// built, so a frame that cannot be banded records nothing.
test "App: a failed band resolution keeps the committed frame and skips GPU dispatch" {
    var session = try Session.init(std.testing.allocator);
    defer session.deinit() catch unreachable;
    var app = try App.init(std.testing.allocator, &session);
    defer app.deinit();
    var root: LayerBumpRoot = .{ .authored = 4, .bump = 2 };
    try app.mountRoot(LayerBumpRoot, &root);

    var gpu: noapi.Gpu = undefined;
    var endpoint: GpuEndpoint = .{ .gpu = &gpu, .retirement_wait_for_test = cpuGpuWait };
    try app.attachGpu(&endpoint);
    var command_buffer: noapi.CommandBuffer = undefined;
    var gpu_frame: GpuFrame = .{
        .endpoint = &endpoint,
        .command_buffer = &command_buffer,
        .extent = .{ .width = 200, .height = 200 },
        .frame_index = 0,
        // A failed frame cancels the recording it was building, so the test
        // hands the App a real cancellation instead of an idle frame.
        .recording = .{ .active = .{ .context = &root, .abort = discardRecording } },
    };
    const first = try app.frameWithGpuAtTime(1, 0, .{ .width = 200, .height = 200 }, &gpu_frame);
    defer if (first.json) |json| std.testing.allocator.free(json);
    const committed = app.tree_ptr orelse return error.MissingCommittedTree;
    try std.testing.expectEqual(@as(u32, 1), root.gpu_frames);

    // The next frame's custom record cannot hold its own layer.
    root.bump = std.math.maxInt(u32);
    gpu_frame.frame_index = 1;
    try std.testing.expectError(
        error.PaintLayerOverflow,
        app.frameWithGpuAtTime(2, 16, .{ .width = 200, .height = 200 }, &gpu_frame),
    );
    // No GPU dispatch for the failed frame, and the published tree is the
    // one that was committed — still readable, still holding its own layer.
    try std.testing.expectEqual(@as(u32, 1), root.gpu_frames);
    try std.testing.expectEqual(@as(*const WidgetTree, committed), app.tree_ptr);
    try std.testing.expectEqual(@as(u64, 1), app.frame_generation);
    var saw_element: usize = 0;
    for (committed.nodes.items) |node| {
        if (node.kind != .element) continue;
        saw_element += 1;
        try std.testing.expectEqual(@as(u32, 6), try widget.effectiveLayer(&node, 2));
    }
    try std.testing.expectEqual(@as(usize, 1), saw_element);
}
