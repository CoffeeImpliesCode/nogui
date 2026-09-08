//! App — the headless run loop: frame arena, component registry, click
//! injection. Per the prototype spec (notes/v7-prototype-spec.md §9).
//!
//! One App owns the component registry (id 1 = the registered root
//! component) and a single ArenaAllocator reused across frames. Every frame
//! resets the arena at its START, builds a FRESH WidgetTree + DrawCtx from
//! the arena (never reuse a tree across a reset — see drawctx.zig), draws
//! the root component, runs canonical layout, and serializes the tree
//! to JSON (gpa-allocated, outlives the frame). Because the reset happens at
//! the start of the *next* frame, the previous frame's tree stays valid
//! until then — FrameOutput.tree documents this lifetime, and it is the
//! handle `click` dispatches against.
const std = @import("std");
const tracy = @import("tracy");

const Id = @import("id.zig").Id;
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
const layout = @import("layout/root.zig");
const Event = @import("event.zig").Event;
const KeyEvent = @import("event.zig").KeyEvent;
const WidgetNode = @import("widget.zig").WidgetNode;
const event = @import("event.zig");
const input = @import("input.zig");
const headless = @import("headless.zig");
const StateDir = @import("state.zig").StateDir;
const perf_counters = @import("perf_counters.zig");
const CounterSink = perf_counters.CounterSink;

const FrameOutput = headless.FrameOutput;

pub const App = struct {
    gpa: std.mem.Allocator,
    layout_storage: layout.LayoutStorage,
    /// Serialize the frame tree to JSON (FrameOutput.json). OFF by
    /// default — the windowed + frames modes never read the JSON, and the
    /// serialization is a measurable per-frame cost. The headless drivers
    /// (--sim, --layout, the demo frames) turn it on.
    serialize_json: bool = false,
    components: std.AutoHashMapUnmanaged(Id, Component) = .empty,
    /// Stable component identity metadata; widget event ownership remains
    /// in `components`, keyed by the frame-local `Id`.
    identity_registry: ComponentRegistry,
    /// Monotonic generation identifying the frame currently being drawn.
    frame_generation: u64 = 0,
    /// Double-buffered frame arenas. Frame N builds into arenas[1-current]
    /// (resetting the tree from two frames ago) while arenas[current] keeps
    /// the PREVIOUS frame's tree alive for the whole of frame N — callers
    /// can diff old vs new by stable id (dirty flags, retained layout,
    /// hitbox carry-over). Both trees are valid until the next frame().
    arenas: [2]std.heap.ArenaAllocator,
    /// Index of the arena holding the most recently built tree.
    current: u32 = 0,
    /// The most recently built tree (in arenas[current]).
    tree_ptr: ?*WidgetTree = null,
    /// Optional host text measurer for the canonical layout dispatcher
    /// (for example, demo-side FreeType advances). Null disables host text
    /// measurement; the v7 core otherwise has no host callback.
    measure: ?layout.MeasureFn = null,
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
    /// Last cursor position in surface pixels (null while outside).
    mouse_pos: ?[2]f32 = null,
    /// Slider being dragged (id from the last presented tree's id space).
    drag_slider: ?Id = null,
    /// The keyboard-focus target (a button/slider id from the last
    /// presented tree). Set by clicks and Tab traversal; the renderer
    /// draws a focus ring.
    focus: ?Id = null,
    /// The button currently held down (pressed visual state).
    pressed: ?Id = null,
    /// Eased 0..1 press-in amount while a button is held: one-pole
    /// smoothed toward 1 (pressed) / 0 (released) on the driver clock,
    /// tau = 60ms. The renderer fades the pressed button with this.
    press_alpha: f32 = 0,
    /// Eased 0..1 hover amount while the cursor is over a node: same
    /// smoother, target = 1 iff the hovered node is non-null.
    hover_alpha: f32 = 0,
    /// Time (ms) of the last .frame event — the driver clock. 0 = no
    /// frame yet; the first frame's dt is 0, not the whole clock value.
    last_time_ms: u64 = 0,
    /// The hovered node of the last presented frame — the fade resets
    /// when the hovered node CHANGES (not just on leave/re-enter), so the
    /// ring re-fades as the cursor travels between widgets.
    last_hover_id: ?Id = null,
    /// The @typeName of the registered root component, recorded by
    /// register(). present() rejects a mismatched caller type.
    root_type_name: []const u8 = "",
    /// The optional renderer endpoint. The endpoint remains owned by the
    /// window driver; App only borrows it while dispatching hooks.
    gpu_endpoint: ?*GpuEndpoint = null,
    /// Optional runner-owned performance counter sink. The disabled build
    /// stores no state and compiles every add to a no-op.
    counter_sink: CounterSink = CounterSink.init(null),

    pub fn init(gpa: std.mem.Allocator) App {
        return .{
            .gpa = gpa,
            .layout_storage = layout.LayoutStorage.init(gpa),
            .identity_registry = ComponentRegistry.init(gpa),
            .arenas = .{
                std.heap.ArenaAllocator.init(gpa),
                std.heap.ArenaAllocator.init(gpa),
            },
            .counter_sink = CounterSink.init(null),
        };
    }

    pub fn setCounterSink(self: *App, counters: ?*perf_counters.Counters) void {
        self.counter_sink = CounterSink.init(counters);
    }

    fn initGpuEntry(self: *App, entry: *ComponentEntry) !void {
        const endpoint = self.gpu_endpoint orelse return;
        if (entry.gpu_initialized) return;
        if (entry.component.vtable.init_gpu) |init_gpu| {
            try init_gpu(entry.component.ptr, endpoint);
        }
        entry.gpu_initialized = true;
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

    /// Detach the renderer endpoint after deinitializing every mounted entry.
    pub fn detachGpu(self: *App) void {
        if (self.gpu_endpoint == null) return;
        var iterator = self.identity_registry.map.iterator();
        while (iterator.next()) |entry| {
            self.deinitGpuEntry(entry.value_ptr);
        }
        self.gpu_endpoint = null;
    }

    pub fn deinit(self: *App) void {
        self.detachGpu();
        self.components.deinit(self.gpa);
        self.identity_registry.deinit();
        self.layout_storage.deinit();
        self.arenas[0].deinit();
        self.arenas[1].deinit();
        self.* = undefined;
    }

    /// Register the root component. Its widget event owner is id 1; its
    /// stable component identity is ComponentId.root.
    pub fn register(self: *App, comptime T: type, ptr: *T) !*Component {
        self.root_type_name = @typeName(T);
        const id: Id = @enumFromInt(1);
        const component = Component.make(T, ptr);
        if (self.identity_registry.map.getPtr(ComponentId.root)) |entry| {
            self.deinitGpuEntry(entry);
        }
        try self.components.put(self.gpa, id, component);
        const entry = try self.identity_registry.map.getOrPut(self.gpa, ComponentId.root);
        entry.value_ptr.* = .{
            .component = component,
            .last_seen_frame = self.frame_generation,
            .gpu_initialized = false,
        };
        if (self.gpu_endpoint != null) {
            try self.initGpuEntry(entry.value_ptr);
        }
        return self.components.getPtr(id) orelse return error.ComponentRegistrationFailed;
    }

    /// Run one frame: swap to the other arena, build a fresh tree + DrawCtx
    /// with `component_id` = the registered root (id 1), draw the root
    /// component, lays out for the current surface, and serializes to JSON.
    ///
    /// Double-buffer lifetime: the returned FrameOutput.tree lives in
    /// arenas[1-current] and stays valid until the frame AFTER next (its
    /// arena is reset by the frame after that). FrameOutput.prev_tree is the
    /// previous frame's tree in arenas[current] — valid until the next
    /// frame() call. Node ids are stable across frames (same draw order), so
    /// prev_tree enables id-keyed diffing. json is gpa-allocated; the caller
    /// owns and frees it.
    /// The driver entry: consume one input event.
    ///   - input events (mouse/resize) mutate the transient input state and
    ///     dispatch against the LAST PRESENTED tree (still valid — the
    ///     double-buffer) — clicks hit what the user actually saw;
    ///   - a `.frame` event draws + lays out + presents, returning the
    ///     frame's output (the driver renders or dumps it).
    /// Returns null for non-frame events.
    pub fn handle(self: *App, comptime T: type, root: *T, ev: Event) !?FrameOutput {
        switch (ev) {
            .frame => |f| return try self.present(T, root, f.tick, f.time_ms, null),
            .resize => |r| {
                self.surface = .{ .width = r.width, .height = r.height };
                return null;
            },
            .mouse_wheel => |wheel| {
                if (self.tree_ptr) |tree| {
                    const hit = input.hitTest(tree, .{ wheel.x, wheel.y }) orelse return null;
                    var current = hit;
                    while (current != .root) {
                        const node = tree.nodeConst(current) orelse break;
                        if (node.scroll) |spec| {
                            const state = spec.state;
                            switch (spec.axis) {
                                .horizontal => {
                                    state.offset[0] = std.math.clamp(
                                        state.offset[0] - wheel.delta_x * 20.0,
                                        0.0,
                                        state.max_offset[0],
                                    );
                                },
                                .vertical => {
                                    state.offset[1] = std.math.clamp(
                                        state.offset[1] - wheel.delta_y * 20.0,
                                        0.0,
                                        state.max_offset[1],
                                    );
                                },
                                .both => {
                                    state.offset[0] = std.math.clamp(
                                        state.offset[0] - wheel.delta_x * 20.0,
                                        0.0,
                                        state.max_offset[0],
                                    );
                                    state.offset[1] = std.math.clamp(
                                        state.offset[1] - wheel.delta_y * 20.0,
                                        0.0,
                                        state.max_offset[1],
                                    );
                                },
                            }
                            break;
                        }
                        current = node.parent;
                    }
                }
                return null;
            },
            .mouse_move => |m| {
                self.mouse_pos = .{ m.x, m.y };
                if (self.drag_slider) |sid| {
                    if (self.tree_ptr) |tree| _ = event.sliderSet(tree, sid, m.x);
                }
                return null;
            },
            .mouse_leave => {
                self.mouse_pos = null;
                // A left mouse_up may never arrive once the pointer has
                // left the window (Alt-Tab, a WM pointer grab, release
                // outside the window) — clear the transient press/drag
                // state here or a button stays visually pressed and a
                // slider drag keeps tracking a ghost pointer.
                self.pressed = null;
                self.drag_slider = null;
                return null;
            },
            .mouse_down => |d| {
                if (self.tree_ptr) |tree| {
                    const pos = [2]f32{ d.x, d.y };
                    if (d.button == .left) {
                        if (input.hitButton(tree, pos)) |id| {
                            event.dispatchClick(tree, .{ .click = .{ .button_id = id } }, &self.components);
                            self.pressed = id;
                            self.focus = id; // clicking focuses
                        } else if (input.hitTest(tree, pos)) |id| {
                            if (event.sliderSet(tree, id, d.x)) {
                                self.drag_slider = id;
                                self.focus = id; // dragging focuses
                            }
                        }
                    }
                }
                return null;
            },
            .mouse_up => |u| {
                if (u.button == .left) {
                    self.drag_slider = null;
                    self.pressed = null;
                }
                return null;
            },
            .key_down => |k| {
                if (self.tree_ptr) |tree| try self.handleKey(tree, k);
                return null;
            },
            .key_up => return null, // repeats arrive as key_down; nothing to clear
            .click => return null, // dispatchClick target; never injected
        }
    }

    /// Built-in key actions (a minimal action map for the prototype):
    ///   Tab / Shift-Tab  — focus traversal over buttons + sliders (wrap)
    ///   Enter / Space    — activate the focused button
    ///   Left/Right/Up/Down — adjust the focused slider (5% steps)
    ///   Home / End       — slider to min / max
    ///   Escape           — clear focus
    fn handleKey(self: *App, tree: *const WidgetTree, k: KeyEvent) !void {
        switch (k.key) {
            .tab => {
                if (k.shift) try self.focusPrev(tree) else try self.focusNext(tree);
            },
            .enter, .space => {
                const fid = self.focus orelse return;
                // Space is the 'commit' key: on a button it clicks, on a
                // slider it jumps to max (End). Enter stays button-only —
                // dispatchClick already no-ops on non-buttons.
                if (k.key == .space) {
                    if (findNode(tree, fid)) |node| {
                        switch (node.kind) {
                            .slider => |s| {
                                s.value.* = s.max;
                                return;
                            },
                            else => {},
                        }
                    }
                }
                event.dispatchClick(tree, .{ .click = .{ .button_id = fid } }, &self.components);
            },
            .left, .right, .up, .down, .home, .end => {
                const fid = self.focus orelse return;
                const node = findNode(tree, fid) orelse return;
                const s = switch (node.kind) {
                    .slider => |s| s,
                    else => return, // only sliders take arrow keys
                };
                const span = s.max - s.min;
                const step: f32 = switch (k.key) {
                    .left, .down => -span * 0.05,
                    .right, .up => span * 0.05,
                    .home => -span, // clamp handles the rest
                    .end => span,
                    else => unreachable,
                };
                s.value.* = std.math.clamp(s.value.* + step, s.min, s.max);
            },
            .escape => self.focus = null,
        }
    }

    /// Move focus to the next/previous focusable node (button or slider)
    /// in the tree, wrapping around. Uses the LAST PRESENTED tree so the
    /// focus order matches what the user sees.
    fn focusNext(self: *App, tree: *const WidgetTree) !void {
        self.focus = try self.focusStep(tree, 1);
    }

    fn focusPrev(self: *App, tree: *const WidgetTree) !void {
        self.focus = try self.focusStep(tree, -1);
    }

    fn focusStep(self: *const App, tree: *const WidgetTree, dir: i32) !?Id {
        // Count focusable nodes first, then size the buffer exactly — a
        // fixed cap would silently drop focusables past it. The slice
        // lives in the app's gpa for the duration of this call only.
        var count: usize = 0;
        for (tree.nodes.items) |*n| {
            if (isTraversable(n)) count += 1;
        }
        if (count == 0) return null;
        const ids = try self.gpa.alloc(Id, count);
        defer self.gpa.free(ids);
        var i: usize = 0;
        for (tree.nodes.items) |*n| {
            if (!isTraversable(n)) continue;
            ids[i] = n.id;
            i += 1;
        }
        // The current focus's index; null when nothing is focused (or the
        // focused node is no longer traversable). Start at the beginning
        // (next) or the end (prev) in that case — never @mod over a -1
        // sentinel, whose off-by-one (@mod(-2, count) = count-2 instead of
        // count-1) would land Shift-Tab one short of the last node.
        var idx: ?usize = null;
        if (self.focus) |f| {
            for (ids, 0..) |id, j| {
                if (id == f) {
                    idx = j;
                    break;
                }
            }
        }
        const next: usize = if (idx) |j|
            @intCast(@mod(@as(i32, @intCast(j)) + dir, @as(i32, @intCast(count))))
        else if (dir > 0) 0 else count - 1;
        return ids[next];
    }

    /// Focus-traversal predicate: buttons and sliders with a laid-out box.
    /// The rect check mirrors input.hitTest — a zero-size node cannot be
    /// seen or reached, so it never takes focus.
    fn isTraversable(n: *const WidgetNode) bool {
        if (n.rect.w <= 0 or n.rect.h <= 0) return false;
        return switch (n.kind) {
            .button, .slider => true,
            else => false,
        };
    }

    /// Id-kind checks for revalidating ids carried over from the previous
    /// frame's tree (see present()). Each returns false when the id is
    /// missing or names a node of a different kind.
    fn isButton(tree: *const WidgetTree, id: Id) bool {
        const node = findNode(tree, id) orelse return false;
        return node.kind == .button;
    }

    fn isFocusableNode(tree: *const WidgetTree, id: Id) bool {
        const node = findNode(tree, id) orelse return false;
        return switch (node.kind) {
            .button, .slider => true,
            else => false,
        };
    }

    fn isSlider(tree: *const WidgetTree, id: Id) bool {
        const node = findNode(tree, id) orelse return false;
        return node.kind == .slider;
    }

    /// Present one frame: the classic frame() entry (tests, one-shot shots)
    /// — the surface is passed explicitly and time starts at 0. The driver
    /// entry is handle(.frame), which uses the driver's surface + clock.
    pub fn frame(self: *App, comptime T: type, root: *T, frame_number: u32, surface: Size) !FrameOutput {
        self.surface = surface;
        return self.present(T, root, frame_number, 0, null);
    }

    /// Present one frame with a borrowed noapi command buffer. The endpoint
    /// must already be attached and must be the frame's endpoint. This
    /// compatibility entry uses the one-shot frame clock (time 0).
    pub fn frameWithGpu(
        self: *App,
        comptime T: type,
        root: *T,
        frame_number: u32,
        surface: Size,
        gpu_frame: *GpuFrame,
    ) !FrameOutput {
        return self.frameWithGpuAtTime(T, root, frame_number, 0, surface, gpu_frame);
    }

    /// Present a driver-timed graphical frame after its Surface frame began.
    /// The caller owns Surface begin/end; App builds and lays out before
    /// dispatching component GPU hooks against `gpu_frame`.
    pub fn frameWithGpuAtTime(
        self: *App,
        comptime T: type,
        root: *T,
        frame_number: u32,
        time_ms: u64,
        surface: Size,
        gpu_frame: *GpuFrame,
    ) !FrameOutput {
        const endpoint = self.gpu_endpoint orelse return error.GpuEndpointNotAttached;
        if (gpu_frame.endpoint != endpoint) return error.GpuFrameEndpointMismatch;
        self.surface = surface;
        return self.present(T, root, frame_number, time_ms, gpu_frame);
    }

    fn findNode(tree: *const WidgetTree, id: Id) ?*const WidgetNode {
        for (tree.nodes.items) |*n| {
            tree.addCounter(.node_comparisons, 1);
            if (n.id == id) return n;
        }
        return null;
    }

    fn dispatchGpuFrame(self: *App, gpu_frame: *GpuFrame) !void {
        const endpoint = self.gpu_endpoint orelse return error.GpuEndpointNotAttached;
        if (gpu_frame.endpoint != endpoint) return error.GpuFrameEndpointMismatch;
        var iterator = self.identity_registry.map.iterator();
        while (iterator.next()) |entry| {
            if (entry.value_ptr.last_seen_frame != self.frame_generation) continue;
            if (!entry.value_ptr.gpu_initialized) continue;
            if (entry.value_ptr.component.vtable.frame_gpu) |frame_gpu| {
                try frame_gpu(entry.value_ptr.component.ptr, gpu_frame);
            }
        }
    }

    fn unmountStaleGpuComponents(self: *App) void {
        var iterator = self.identity_registry.map.iterator();
        while (iterator.next()) |entry| {
            if (entry.value_ptr.last_seen_frame == self.frame_generation) continue;
            const identity = entry.key_ptr.*;
            self.deinitGpuEntry(entry.value_ptr);
            _ = self.identity_registry.map.remove(identity);
        }
    }

    fn present(
        self: *App,
        comptime T: type,
        root: *T,
        frame_number: u32,
        time_ms: u64,
        gpu_frame: ?*GpuFrame,
    ) !FrameOutput {
        const root_component = self.components.get(@enumFromInt(1)) orelse
            return error.RootNotRegistered;
        // Type-confusion guard: register() recorded @typeName(T), and the
        // vtable's draw is type-erased — presenting with a DIFFERENT type
        // would dispatch the registered type's draw on the caller's memory
        // (A's draw reading B's fields). The registered type lives only in
        // the runtime registry, so the check is a runtime panic; it cannot
        // be a comptime @compileError — Zig analyzes both branches of a
        // runtime `if` (the error would fire for every caller) and
        // comptime fields cannot be assigned by register().
        if (!std.mem.eql(u8, self.root_type_name, @typeName(T))) {
            @panic("App: frame()/handle() called with a root type different from the one register() stored");
        }
        self.frame_generation +%= 1;
        const build_idx: u32 = 1 - self.current;
        // Reset the arena holding the tree from two frames ago. The other
        // arena keeps the previous frame's tree alive during this build.
        {
            const zone = tracy.Zone.begin(.{ .name = "arenaReset", .src = @src() });
            defer zone.end();
            _ = self.arenas[build_idx].reset(.retain_capacity);
        }

        if (@hasField(T, "frame_count")) root.frame_count = frame_number;
        const surface = self.surface;
        try layout.validateAvailable(surface);

        const arena_alloc = self.arenas[build_idx].allocator();
        const tree = try arena_alloc.create(WidgetTree);
        tree.* = WidgetTree.init(arena_alloc);
        tree.setCounterSink(self.counter_sink.pointer());
        // The registered ROOT component occupies id 1; the tree's node and
        // nested-component ids must never collide with it, so the counter
        // starts at 2.
        tree.next_id = 2;
        // The state directory lives in THIS frame's arena; the previous
        // frame's directory (state_prev) points into the other arena, still
        // alive — that is the store state() seeds from.
        const state_dir = try arena_alloc.create(StateDir);
        const root_entry = try self.identity_registry.map.getOrPut(self.gpa, ComponentId.root);
        root_entry.value_ptr.component = root_component;
        root_entry.value_ptr.last_seen_frame = self.frame_generation;
        if (!root_entry.found_existing) {
            root_entry.value_ptr.gpu_initialized = false;
        }
        if (self.gpu_endpoint != null) {
            try self.initGpuEntry(root_entry.value_ptr);
        }
        state_dir.* = .empty;
        var ctx: DrawCtx = .{
            .tree = tree,
            .arena = arena_alloc,
            .surface = surface,
            .component_id = @enumFromInt(1), // legacy widget event owner
            .component_identity = ComponentId.root,
            .frame_generation = self.frame_generation,
            .state_prev = self.state_prev,
            .state_cur = state_dir,
            .registry = .{ .map = &self.components, .gpa = self.gpa },
            .identity_map = &self.identity_registry,
            .gpu_endpoint = self.gpu_endpoint,
        };

        // Draw the registered root through its vtable. `root` is the same
        // pointer register() stored, so click dispatch targets it too.
        {
            const zone = tracy.Zone.begin(.{ .name = "appDraw", .src = @src() });
            defer zone.end();
            try root_component.vtable.draw(root, &ctx);
        }

        {
            const zone = tracy.Zone.begin(.{ .name = "layoutTree", .src = @src() });
            defer zone.end();
            try layout.layoutTree(tree, .{
                .allocator = arena_alloc,
                .available = surface,
                .measure = self.measure,
                .storage = &self.layout_storage,
            });
        }
        defer self.unmountStaleGpuComponents();
        if (gpu_frame) |active_gpu_frame| {
            const zone = tracy.Zone.begin(.{ .name = "gpuComponentDispatch", .src = @src() });
            defer zone.end();
            try self.dispatchGpuFrame(active_gpu_frame);
        }

        const state_zone = tracy.Zone.begin(.{ .name = "stateInputValidation", .src = @src() });
        defer state_zone.end();
        // Revalidate ids carried over from the previous frame's tree.
        // Draw order can change between frames (a conditional node inserted
        // above renumbers everything after it), so an id may now name a
        // DIFFERENT node or nothing. Clear the id when its node is missing
        // or its kind changed — never re-bind it to the new occupant of
        // the old position. A slider that vanished mid-drag ends the drag:
        // the stale drag_slider must not keep tracking mouse_move.
        if (self.focus) |f| {
            if (!isFocusableNode(tree, f)) self.focus = null;
        }
        if (self.pressed) |p| {
            if (!isButton(tree, p)) self.pressed = null;
        }
        if (self.drag_slider) |s| {
            if (!isSlider(tree, s)) self.drag_slider = null;
        }

        // The hovered node under the driver's cursor — the renderer draws
        // its outline without re-running its own hit test.
        const hover: ?Id = if (self.mouse_pos) |p| input.hitTest(tree, p) else null;
        const focus = self.focus;
        const pressed = self.pressed;

        // Time-driven eased visual states (one-pole smoothers). Hover is
        // deliberately slow (tau 180ms — a perceivable ring fade), press is
        // snappier (tau 100ms — responsive but not instant). The driver
        // clock (Event.frame.time_ms) is the ONLY clock; input events
        // between frames use the last frame's time. dt is clamped to
        // [0, 250]ms so a driver pause (no .frame events) cannot jump
        // the fade, and the first frame (last_time_ms = 0) yields dt = 0.
        const dt: u64 = @min(time_ms -| self.last_time_ms, 250);
        self.last_time_ms = time_ms;
        const dt_f: f32 = @floatFromInt(dt);
        const k_press = 1.0 - std.math.exp(-dt_f / 100.0);
        const k_hover = 1.0 - std.math.exp(-dt_f / 180.0);
        const press_target: f32 = if (pressed != null) 1.0 else 0.0;
        self.press_alpha += (press_target - self.press_alpha) * k_press;
        // Hover: the fade replays on WIDGET-TO-WIDGET transitions — a
        // binary target would only fade on leave/re-enter, leaving the
        // ring solid while the cursor travels between widgets. Leave
        // (→ null) and re-enter (null →) keep the natural ramp, so the
        // ring still fades out on exit.
        const hover_changed = (hover != null) and
            (self.last_hover_id != null) and
            !std.meta.eql(hover, self.last_hover_id);
        self.last_hover_id = hover;
        const hover_target: f32 = if (hover != null) 1.0 else 0.0;
        if (hover_changed) self.hover_alpha = 0;
        self.hover_alpha += (hover_target - self.hover_alpha) * k_hover;

        const json: ?[]const u8 = if (self.serialize_json) blk: {
            const zone = tracy.Zone.begin(.{ .name = "treeToJson", .src = @src() });
            defer zone.end();
            break :blk try headless.treeToJson(self.gpa, tree);
        } else null;
        // Swap the state directory: next frame seeds from THIS frame's
        // live values (their arena survives the next build).
        self.state_prev = state_dir;
        const prev_tree = self.tree_ptr;
        self.current = build_idx;
        self.tree_ptr = tree;
        return .{
            .frame_number = frame_number,
            .time_ms = time_ms,
            .json = json,
            .tree = tree,
            .prev_tree = prev_tree,
            .hover = hover,
            .focus = focus,
            .pressed = pressed,
            .press_alpha = self.press_alpha,
            .hover_alpha = self.hover_alpha,
        };
    }

    /// Inject a click. Dispatches against the given tree — typically the
    /// current frame's `FrameOutput.tree` — via event.dispatchClick.
    /// No-op (return) if the node is missing, not a button, has no on_click,
    /// or its owner is not registered.
    pub fn click(self: *App, tree: *const WidgetTree, button_id: Id) void {
        event.dispatchClick(tree, .{ .click = .{ .button_id = button_id } }, &self.components);
    }
};

// --- tests ---------------------------------------------------------------

test "App: frame without a registered root returns RootNotRegistered" {
    const Root = struct {
        const Self = @This();

        pub fn draw(_: *Self, _: *DrawCtx) !void {}
    };

    var app = App.init(std.testing.allocator);
    defer app.deinit();

    var root: Root = .{};
    try std.testing.expectError(
        error.RootNotRegistered,
        app.frame(Root, &root, 1, .{ .width = 100, .height = 100 }),
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

    var app = App.init(std.testing.allocator);
    defer app.deinit();

    var root: Root = .{};
    _ = try app.register(Root, &root);

    try std.testing.expectError(
        error.InvalidStyle,
        app.frame(Root, &root, 1, .{
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
        _ = try ctx.button(.{ .label = "Increment", .on_click = Counter.onClick });
    }

    pub fn onClick(self: *Counter) void {
        self.count += 1;
    }
};

/// First `.button` node in the tree. Node order is post-order (children
/// before containers) and ids are not positions — scan by kind, never by
/// index arithmetic.
fn firstButton(tree: *const WidgetTree) ?Id {
    for (tree.nodes.items) |*n| {
        if (n.kind == .button) return n.id;
    }
    return null;
}

test "App: three frames with click injection persist state across frames" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();
    app.serialize_json = true;

    var counter: Counter = .{};
    _ = try app.register(Counter, &counter);

    // Frame 1: find the first .button node in the frame tree and click it
    // while the tree is still valid (dies at the next frame's arena reset).
    const out1 = try app.frame(Counter, &counter, 1, .{ .width = 800, .height = 600 });
    defer if (out1.json) |j| std.testing.allocator.free(j);
    const json1 = out1.json orelse return error.MissingFrameJson;
    try std.testing.expect(std.mem.indexOf(u8, json1, "Count: 0") != null);

    const btn = firstButton(out1.tree) orelse return error.MissingButton;
    app.click(out1.tree, btn);

    // Frames 2-3: the incremented count persists — no dirty tracking.
    const out2 = try app.frame(Counter, &counter, 2, .{ .width = 800, .height = 600 });
    defer if (out2.json) |j| std.testing.allocator.free(j);
    const json2 = out2.json orelse return error.MissingFrameJson;
    try std.testing.expect(std.mem.indexOf(u8, json2, "Count: 1") != null);

    const out3 = try app.frame(Counter, &counter, 3, .{ .width = 800, .height = 600 });
    defer if (out3.json) |j| std.testing.allocator.free(j);
    const json3 = out3.json orelse return error.MissingFrameJson;
    try std.testing.expect(std.mem.indexOf(u8, json3, "Count: 1") != null);
}

test "App: frame tree exposes button nodes owned by the registered root" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();

    var counter: Counter = .{};
    _ = try app.register(Counter, &counter);

    const out = try app.frame(Counter, &counter, 1, .{ .width = 800, .height = 600 });
    defer if (out.json) |j| std.testing.allocator.free(j);

    // Scan by kind; every .button node binds its owner to the registered
    // root component (id 1), so click dispatch can reach it.
    var found: usize = 0;
    for (out.tree.nodes.items) |n| {
        if (n.kind != .button) continue;
        found += 1;
        try std.testing.expectEqual(@as(Id, @enumFromInt(1)), n.kind.button.owner);
    }
    try std.testing.expect(found >= 1);
}

test "App: click on an unknown id is a no-op and the next frame still renders" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();
    app.serialize_json = true;

    var counter: Counter = .{};
    _ = try app.register(Counter, &counter);

    const out1 = try app.frame(Counter, &counter, 1, .{ .width = 800, .height = 600 });
    defer if (out1.json) |j| std.testing.allocator.free(j);

    app.click(out1.tree, @enumFromInt(999)); // no such node in the tree

    const out2 = try app.frame(Counter, &counter, 2, .{ .width = 800, .height = 600 });
    defer if (out2.json) |j| std.testing.allocator.free(j);
    const json = out2.json orelse return error.MissingFrameJson;
    try std.testing.expect(std.mem.indexOf(u8, json, "Count: 0") != null);
}

/// Text of the first .label node with the given id (null when missing).
fn labelTextById(tree: *const WidgetTree, id: Id) ?[]const u8 {
    for (tree.nodes.items) |*n| {
        if (n.id != id) continue;
        switch (n.kind) {
            .label => |l| return l.text,
            else => return null,
        }
    }
    return null;
}

test "App: ctx.state persists per node across frames, resets after unmount" {
    var app = App.init(std.testing.allocator);
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
    _ = try app.register(Comp, &comp);

    // Frame 1: fresh node -> init 0, incremented to 1.
    const out1 = try app.frame(Comp, &comp, 1, .{ .width = 100, .height = 100 });
    defer if (out1.json) |j| std.testing.allocator.free(j);
    const first_state = comp.last orelse return error.MissingState;
    try std.testing.expectEqual(@as(u32, 1), first_state.*);

    // Frame 2: the last version (1) was copied over -> 2.
    const out2 = try app.frame(Comp, &comp, 2, .{ .width = 100, .height = 100 });
    defer if (out2.json) |j| std.testing.allocator.free(j);
    const second_state = comp.last orelse return error.MissingState;
    try std.testing.expectEqual(@as(u32, 2), second_state.*);

    // Frame 3: unmount — the node is not drawn; its state directory entry
    // dies with the frame.
    comp.show = false;
    const out3 = try app.frame(Comp, &comp, 3, .{ .width = 100, .height = 100 });
    defer if (out3.json) |j| std.testing.allocator.free(j);
    try std.testing.expectEqual(@as(?*u32, null), comp.last);

    // Frame 4: remount -> fresh init again (0 -> 1), not 3.
    comp.show = true;
    const out4 = try app.frame(Comp, &comp, 4, .{ .width = 100, .height = 100 });
    defer if (out4.json) |j| std.testing.allocator.free(j);
    const remounted_state = comp.last orelse return error.MissingState;
    try std.testing.expectEqual(@as(u32, 1), remounted_state.*);
}

test "App: double-buffer — prev_tree is the previous frame's tree with stable ids" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();
    var counter: Counter = .{};
    _ = try app.register(Counter, &counter);

    // Frame 1: no previous tree yet.
    const out1 = try app.frame(Counter, &counter, 1, .{ .width = 800, .height = 600 });
    defer if (out1.json) |j| std.testing.allocator.free(j);
    try std.testing.expectEqual(@as(?*const WidgetTree, null), out1.prev_tree);

    var label1: ?Id = null;
    for (out1.tree.nodes.items) |*n| {
        if (n.kind == .label) {
            label1 = n.id;
            break;
        }
    }
    const label_id = label1 orelse return error.MissingLabel;
    const rect1 = blk: {
        for (out1.tree.nodes.items) |*n| {
            if (n.id == label_id) break :blk n.rect;
        }
        unreachable;
    };

    // Frame 2: the label text changed; ids and rects did not.
    counter.count += 1;
    const out2 = try app.frame(Counter, &counter, 2, .{ .width = 800, .height = 600 });
    defer if (out2.json) |j| std.testing.allocator.free(j);

    // prev_tree IS frame 1's tree — still fully readable after the swap.
    try std.testing.expect(out2.prev_tree == out1.tree);
    const previous_tree = out2.prev_tree orelse return error.MissingPreviousTree;
    const previous_label = labelTextById(previous_tree, label_id) orelse
        return error.MissingLabelText;
    try std.testing.expectEqualStrings("Count: 0", previous_label);
    const current_label = labelTextById(out2.tree, label_id) orelse
        return error.MissingLabelText;
    try std.testing.expectEqualStrings("Count: 1", current_label);

    // Same id, same rect — only the text differs: id-keyed diffing (dirty
    // flags, retained layout) can detect the change cheaply.
    const rect2 = blk: {
        for (out2.tree.nodes.items) |*n| {
            if (n.id == label_id) break :blk n.rect;
        }
        unreachable;
    };
    try std.testing.expectEqual(rect1, rect2);

    // Frame 3: the swap advanced — prev_tree is now frame 2's tree.
    const out3 = try app.frame(Counter, &counter, 3, .{ .width = 800, .height = 600 });
    defer if (out3.json) |j| std.testing.allocator.free(j);
    try std.testing.expect(out3.prev_tree == out2.tree);

    // Frame 1's tree is gone (its arena was reset) — but frame 2's tree
    // (out2.tree) is STILL alive as out3's prev_tree, so click dispatch and
    // hit-testing against the presented tree stay valid one frame longer.
    const previous_tree_after_swap = out3.prev_tree orelse return error.MissingPreviousTree;
    const previous_label_after_swap = labelTextById(previous_tree_after_swap, label_id) orelse
        return error.MissingLabelText;
    try std.testing.expectEqualStrings("Count: 1", previous_label_after_swap);
}

test "App: driver — hover, click and slider drag through handle()" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();

    const Widgets = struct {
        const Self = @This();

        clicks: u32 = 0,
        volume: f32 = 0.5,

        pub fn draw(self: *Self, ctx: *DrawCtx) !void {
            _ = try ctx.column(.{});
            defer ctx.pop();
            _ = try ctx.slider(.{ .label = "s", .value = &self.volume, .min = 0, .max = 1 });
            _ = try ctx.button(.{ .label = "go", .on_click = Self.onClick });
        }

        fn onClick(self: *Self) void {
            self.clicks += 1;
        }
    };
    var widgets: Widgets = .{};
    _ = try app.register(Widgets, &widgets);

    // The driver sizes the surface first; then frame 1 draws at 200x200.
    _ = try app.handle(Widgets, &widgets, .{ .resize = .{ .width = 200, .height = 200 } });
    const out1 = (try app.handle(Widgets, &widgets, .{ .frame = .{ .tick = 1, .time_ms = 0 } })) orelse
        return error.MissingFrameOutput;
    defer if (out1.json) |j| std.testing.allocator.free(j);

    const button_id = firstButton(out1.tree) orelse return error.MissingButton;
    const button_rect = widget.absoluteRect(out1.tree, button_id);
    try std.testing.expect(button_rect.w > 0);
    try std.testing.expect(button_rect.h > 0);
    const button_x = button_rect.x + button_rect.w * 0.1;
    const button_y = button_rect.y + button_rect.h / 2;

    _ = try app.handle(Widgets, &widgets, .{ .mouse_move = .{ .x = button_x, .y = button_y } });
    const out2 = (try app.handle(Widgets, &widgets, .{ .frame = .{ .tick = 2, .time_ms = 16 } })) orelse
        return error.MissingFrameOutput;
    defer if (out2.json) |j| std.testing.allocator.free(j);
    const hover_id = out2.hover orelse return error.MissingHoverTarget;
    try std.testing.expectEqual(button_id, hover_id);

    // Click the button through the current laid-out hit box.
    _ = try app.handle(Widgets, &widgets, .{ .mouse_down = .{ .button = .left, .x = button_x, .y = button_y } });
    _ = try app.handle(Widgets, &widgets, .{ .mouse_up = .{ .button = .left, .x = button_x, .y = button_y } });
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

    _ = try app.handle(Widgets, &widgets, .{ .mouse_down = .{ .button = .left, .x = slider_start_x, .y = slider_y } });
    _ = try app.handle(Widgets, &widgets, .{ .mouse_move = .{ .x = slider_value_x, .y = slider_y } });
    try std.testing.expectEqual(@as(f32, 0.3), widgets.volume);
    _ = try app.handle(Widgets, &widgets, .{ .mouse_up = .{ .button = .left, .x = slider_value_x, .y = slider_y } });
    // The drag ended: further moves do nothing.
    _ = try app.handle(Widgets, &widgets, .{
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

    var app = App.init(std.testing.allocator);
    defer app.deinit();
    var widgets: ScrollWidgets = .{};
    widgets.state.max_offset = .{ 0, 60 };
    widgets.state.offset = .{ 0, 10 };
    _ = try app.register(ScrollWidgets, &widgets);

    _ = try app.handle(ScrollWidgets, &widgets, .{
        .resize = .{ .width = 200, .height = 100 },
    });
    const out = (try app.handle(ScrollWidgets, &widgets, .{
        .frame = .{ .tick = 1, .time_ms = 0 },
    })) orelse return error.MissingFrameOutput;
    // Layout computes max_offset from content overflow. Set a bounded
    // limit here so this test isolates wheel scaling and clamping.
    widgets.state.max_offset = .{ 0, 60 };
    defer if (out.json) |json| std.testing.allocator.free(json);

    // Negative wheel delta moves content down, increasing the scroll offset.
    _ = try app.handle(ScrollWidgets, &widgets, .{
        .mouse_wheel = .{
            .x = 1,
            .y = 1,
            .delta_x = 0,
            .delta_y = -2,
        },
    });
    try std.testing.expectEqual(@as(f32, 50), widgets.state.offset[1]);

    // A second negative delta stops at max_offset rather than overshooting.
    _ = try app.handle(ScrollWidgets, &widgets, .{
        .mouse_wheel = .{
            .x = 1,
            .y = 1,
            .delta_x = 0,
            .delta_y = -2,
        },
    });
    try std.testing.expectEqual(@as(f32, 60), widgets.state.offset[1]);

    // A large positive delta stops at the zero floor.
    _ = try app.handle(ScrollWidgets, &widgets, .{
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
    const Dummy = struct {};

    var app = App.init(std.testing.allocator);
    defer app.deinit();
    var dummy: Dummy = .{};

    var tree = WidgetTree.init(std.testing.allocator);
    defer tree.deinit();
    var outer_state: ScrollState = .{
        .max_offset = .{ 0, 100 },
    };
    var inner_state: ScrollState = .{
        .max_offset = .{ 0, 100 },
    };
    const outer_id: Id = @enumFromInt(1);
    const inner_id: Id = @enumFromInt(2);
    const child_id: Id = @enumFromInt(3);

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

    _ = try app.handle(Dummy, &dummy, .{
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
    var app = App.init(std.testing.allocator);
    defer app.deinit();

    const Widgets = struct {
        const Self = @This();

        clicks: u32 = 0,
        volume: f32 = 0.5,

        pub fn draw(self: *Self, ctx: *DrawCtx) !void {
            _ = try ctx.column(.{});
            defer ctx.pop();
            _ = try ctx.slider(.{ .label = "s", .value = &self.volume, .min = 0, .max = 1 });
            _ = try ctx.button(.{ .label = "a", .on_click = Self.onClick });
            _ = try ctx.button(.{ .label = "b", .on_click = Self.onClick });
        }

        fn onClick(self: *Self) void {
            self.clicks += 1;
        }
    };
    var widgets: Widgets = .{};
    _ = try app.register(Widgets, &widgets);

    _ = try app.handle(Widgets, &widgets, .{ .resize = .{ .width = 200, .height = 200 } });
    const out1 = (try app.handle(Widgets, &widgets, .{ .frame = .{ .tick = 1, .time_ms = 0 } })) orelse
        return error.MissingFrameOutput;
    defer if (out1.json) |j| std.testing.allocator.free(j);

    // Focusable order (append order): slider, button a, button b.
    const ids = blk: {
        var found: [3]Id = undefined;
        var n: usize = 0;
        for (out1.tree.nodes.items) |*node| {
            switch (node.kind) {
                .slider => {
                    found[n] = node.id;
                    n += 1;
                },
                .button => {
                    found[n] = node.id;
                    n += 1;
                },
                else => {},
            }
        }
        break :blk found;
    };

    // Tab: focus the first focusable (the slider); frame 2 reports it.
    _ = try app.handle(Widgets, &widgets, .{ .key_down = .{ .key = .tab, .shift = false } });
    const out2 = (try app.handle(Widgets, &widgets, .{ .frame = .{ .tick = 2, .time_ms = 16 } })) orelse
        return error.MissingFrameOutput;
    defer if (out2.json) |j| std.testing.allocator.free(j);
    const focused_id = out2.focus orelse return error.MissingFocus;
    try std.testing.expectEqual(ids[0], focused_id);

    // Tab: focus button a. Space: activate it -> clicks.
    _ = try app.handle(Widgets, &widgets, .{ .key_down = .{ .key = .tab, .shift = false } });
    _ = try app.handle(Widgets, &widgets, .{ .key_down = .{ .key = .space, .shift = false } });
    try std.testing.expectEqual(@as(u32, 1), widgets.clicks);

    // Right arrow on the focused slider: volume += 5% of the range.
    _ = try app.handle(Widgets, &widgets, .{ .key_down = .{ .key = .tab, .shift = true } }); // back to the slider
    _ = try app.handle(Widgets, &widgets, .{ .key_down = .{ .key = .right, .shift = false } });
    try std.testing.expectEqual(@as(f32, 0.55), widgets.volume);
    _ = try app.handle(Widgets, &widgets, .{ .key_down = .{ .key = .end, .shift = false } });
    try std.testing.expectEqual(@as(f32, 1), widgets.volume);

    // Escape clears focus.
    _ = try app.handle(Widgets, &widgets, .{ .key_down = .{ .key = .escape, .shift = false } });
    const out3 = (try app.handle(Widgets, &widgets, .{ .frame = .{ .tick = 3, .time_ms = 32 } })) orelse
        return error.MissingFrameOutput;
    defer if (out3.json) |j| std.testing.allocator.free(j);
    try std.testing.expectEqual(@as(?Id, null), out3.focus);
}

test "App: focus/pressed cleared when a draw-order change renumbers ids" {
    var app = App.init(std.testing.allocator);
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
            _ = try ctx.button(.{ .label = "go", .on_click = Self.noop });
        }

        fn noop(self: *Self) void {
            _ = self;
        }
    };
    var comp: Comp = .{};
    _ = try app.register(Comp, &comp);

    _ = try app.handle(Comp, &comp, .{ .resize = .{ .width = 200, .height = 200 } });
    const out1 = (try app.handle(Comp, &comp, .{ .frame = .{ .tick = 1, .time_ms = 0 } })) orelse
        return error.MissingFrameOutput;
    defer if (out1.json) |j| std.testing.allocator.free(j);

    // The button is the column's first child at (0,0,...); press it:
    // mouse_down focuses AND presses.
    _ = try app.handle(Comp, &comp, .{ .mouse_down = .{ .button = .left, .x = 5, .y = 5 } });
    const out2 = (try app.handle(Comp, &comp, .{ .frame = .{ .tick = 2, .time_ms = 16 } })) orelse
        return error.MissingFrameOutput;
    defer if (out2.json) |j| std.testing.allocator.free(j);
    try std.testing.expect(out2.focus != null);
    try std.testing.expect(out2.pressed != null);
    const stale = out2.focus orelse return error.MissingFocus;

    // Insert the conditional node ABOVE the button: ids renumber, so the
    // stale id now names the LABEL. The stale focus/pressed are cleared —
    // never re-bound to the new occupant of the old position.
    comp.show_extra = true;
    const out3 = (try app.handle(Comp, &comp, .{ .frame = .{ .tick = 3, .time_ms = 32 } })) orelse
        return error.MissingFrameOutput;
    defer if (out3.json) |j| std.testing.allocator.free(j);
    try std.testing.expectEqual(@as(?Id, null), out3.focus);
    try std.testing.expectEqual(@as(?Id, null), out3.pressed);

    // Sanity: the renumbering really happened — the stale id now belongs
    // to the label, and the button moved to a different id.
    const stale_node = out3.tree.nodeConst(stale) orelse return error.MissingStaleNode;
    try std.testing.expect(stale_node.kind == .label);
    var button_moved = false;
    for (out3.tree.nodes.items) |*n| {
        if (n.kind == .button) button_moved = n.id != stale;
    }
    try std.testing.expect(button_moved);
}

test "App: keyboard — no focus: Tab lands on the first, Shift-Tab on the last" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();

    const Comp = struct {
        const Self = @This();

        pub fn draw(self: *Self, ctx: *DrawCtx) !void {
            _ = self;
            _ = try ctx.column(.{});
            defer ctx.pop();
            _ = try ctx.button(.{ .label = "a" });
            _ = try ctx.button(.{ .label = "b" });
            _ = try ctx.button(.{ .label = "c" });
        }
    };
    var comp: Comp = .{};
    _ = try app.register(Comp, &comp);

    _ = try app.handle(Comp, &comp, .{ .resize = .{ .width = 200, .height = 200 } });
    const out1 = (try app.handle(Comp, &comp, .{ .frame = .{ .tick = 1, .time_ms = 0 } })) orelse
        return error.MissingFrameOutput;
    defer if (out1.json) |j| std.testing.allocator.free(j);

    const ids = blk: {
        var found: [3]Id = undefined;
        var n: usize = 0;
        for (out1.tree.nodes.items) |*node| {
            if (node.kind != .button) continue;
            found[n] = node.id;
            n += 1;
        }
        try std.testing.expectEqual(@as(usize, 3), n);
        break :blk found;
    };

    // No focus + Tab -> the FIRST focusable.
    _ = try app.handle(Comp, &comp, .{ .key_down = .{ .key = .tab, .shift = false } });
    const out2 = (try app.handle(Comp, &comp, .{ .frame = .{ .tick = 2, .time_ms = 16 } })) orelse
        return error.MissingFrameOutput;
    defer if (out2.json) |j| std.testing.allocator.free(j);
    const first_focus = out2.focus orelse return error.MissingFocus;
    try std.testing.expectEqual(ids[0], first_focus);

    // No focus + Shift-Tab -> the LAST focusable (the old @mod(-2, count)
    // sentinel bug landed on count-2 instead of count-1).
    _ = try app.handle(Comp, &comp, .{ .key_down = .{ .key = .escape, .shift = false } });
    _ = try app.handle(Comp, &comp, .{ .key_down = .{ .key = .tab, .shift = true } });
    const out3 = (try app.handle(Comp, &comp, .{ .frame = .{ .tick = 3, .time_ms = 32 } })) orelse
        return error.MissingFrameOutput;
    defer if (out3.json) |j| std.testing.allocator.free(j);
    const last_focus = out3.focus orelse return error.MissingFocus;
    try std.testing.expectEqual(ids[2], last_focus);
}

test "App: mouse_leave clears pressed and drag_slider without a mouse_up" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();

    const Comp = struct {
        const Self = @This();

        volume: f32 = 0.5,

        pub fn draw(self: *Self, ctx: *DrawCtx) !void {
            _ = try ctx.column(.{});
            defer ctx.pop();
            _ = try ctx.slider(.{ .label = "s", .value = &self.volume, .min = 0, .max = 1 });
            _ = try ctx.button(.{ .label = "go" });
        }
    };
    var comp: Comp = .{};
    _ = try app.register(Comp, &comp);

    _ = try app.handle(Comp, &comp, .{ .resize = .{ .width = 200, .height = 200 } });
    const out1 = (try app.handle(Comp, &comp, .{ .frame = .{ .tick = 1, .time_ms = 0 } })) orelse
        return error.MissingFrameOutput;
    defer if (out1.json) |j| std.testing.allocator.free(j);

    const button_id = firstButton(out1.tree) orelse return error.MissingButton;
    const button_rect = widget.absoluteRect(out1.tree, button_id);
    const button_x = button_rect.x + button_rect.w * 0.1;
    const button_y = button_rect.y + button_rect.h / 2;
    _ = try app.handle(Comp, &comp, .{ .mouse_down = .{ .button = .left, .x = button_x, .y = button_y } });
    const out2 = (try app.handle(Comp, &comp, .{ .frame = .{ .tick = 2, .time_ms = 16 } })) orelse
        return error.MissingFrameOutput;
    defer if (out2.json) |j| std.testing.allocator.free(j);
    const pressed_id = out2.pressed orelse return error.MissingPressedButton;
    try std.testing.expectEqual(button_id, pressed_id);

    // The pointer leaves the window with the button still held; no mouse_up
    // ever arrives (Alt-Tab, WM grab, release outside). pressed clears.
    _ = try app.handle(Comp, &comp, .{ .mouse_leave = {} });
    const out3 = (try app.handle(Comp, &comp, .{ .frame = .{ .tick = 3, .time_ms = 32 } })) orelse
        return error.MissingFrameOutput;
    defer if (out3.json) |j| std.testing.allocator.free(j);
    try std.testing.expectEqual(@as(?Id, null), out3.pressed);

    const slider_id = blk: {
        for (out3.tree.nodes.items) |*node| {
            if (node.kind == .slider) break :blk node.id;
        }
        unreachable;
    };
    const slider_rect = widget.absoluteRect(out3.tree, slider_id);
    const slider_y = slider_rect.y + slider_rect.h / 2;
    const slider_value_x = slider_rect.x + slider_rect.w * 0.3;

    // Leaving the window also ends an active slider drag.
    _ = try app.handle(Comp, &comp, .{ .mouse_move = .{ .x = slider_value_x, .y = slider_y } });
    _ = try app.handle(Comp, &comp, .{ .mouse_down = .{ .button = .left, .x = slider_value_x, .y = slider_y } });
    try std.testing.expectEqual(@as(f32, 0.3), comp.volume);
    _ = try app.handle(Comp, &comp, .{ .mouse_leave = {} });
    _ = try app.handle(Comp, &comp, .{ .mouse_move = .{ .x = slider_rect.x + slider_rect.w * 0.9, .y = slider_y } });
    try std.testing.expectEqual(@as(f32, 0.3), comp.volume);
}

test "App: keyboard — Space on a focused slider jumps to max; Enter stays button-only" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();

    const Comp = struct {
        const Self = @This();

        clicks: u32 = 0,
        volume: f32 = 0.2,

        pub fn draw(self: *Self, ctx: *DrawCtx) !void {
            _ = try ctx.column(.{});
            defer ctx.pop();
            _ = try ctx.slider(.{ .label = "s", .value = &self.volume, .min = 0, .max = 1 });
            _ = try ctx.button(.{ .label = "go", .on_click = Self.onClick });
        }

        fn onClick(self: *Self) void {
            self.clicks += 1;
        }
    };
    var comp: Comp = .{};
    _ = try app.register(Comp, &comp);

    _ = try app.handle(Comp, &comp, .{ .resize = .{ .width = 200, .height = 200 } });
    const out1 = (try app.handle(Comp, &comp, .{ .frame = .{ .tick = 1, .time_ms = 0 } })) orelse
        return error.MissingFrameOutput;
    defer if (out1.json) |j| std.testing.allocator.free(j);

    // Tab -> focus the slider (first focusable); Space = End: value to max,
    // no click dispatched (sliders have no handler).
    _ = try app.handle(Comp, &comp, .{ .key_down = .{ .key = .tab, .shift = false } });
    _ = try app.handle(Comp, &comp, .{ .key_down = .{ .key = .space, .shift = false } });
    try std.testing.expectEqual(@as(f32, 1), comp.volume);
    try std.testing.expectEqual(@as(u32, 0), comp.clicks);

    // Enter on the same slider: still no click, value untouched.
    _ = try app.handle(Comp, &comp, .{ .key_down = .{ .key = .enter, .shift = false } });
    try std.testing.expectEqual(@as(f32, 1), comp.volume);
    try std.testing.expectEqual(@as(u32, 0), comp.clicks);
}

test "App: keyboard — focus traversal reaches the 70th focusable (no 64 cap)" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();

    const Many = struct {
        const Self = @This();

        pub fn draw(self: *Self, ctx: *DrawCtx) !void {
            _ = self;
            _ = try ctx.column(.{});
            defer ctx.pop();
            for (0..70) |_| {
                _ = try ctx.button(.{ .label = "b" });
            }
        }
    };
    var comp: Many = .{};
    _ = try app.register(Many, &comp);

    _ = try app.handle(Many, &comp, .{ .resize = .{ .width = 200, .height = 600 } });
    const out = (try app.handle(Many, &comp, .{ .frame = .{ .tick = 1, .time_ms = 0 } })) orelse
        return error.MissingFrameOutput;
    defer if (out.json) |j| std.testing.allocator.free(j);

    var button_ids: [70]Id = undefined;
    var n: usize = 0;
    for (out.tree.nodes.items) |*node| {
        if (node.kind != .button) continue;
        button_ids[n] = node.id;
        n += 1;
    }
    try std.testing.expectEqual(@as(usize, 70), n);

    // 70 Tabs from no focus: the 70th Tab lands on the LAST focusable.
    // (The old fixed [64] buffer silently dropped focusables 65+, so the
    // 70th button was unreachable.)
    var last_focus: ?Id = null;
    for (0..70) |i| {
        _ = try app.handle(Many, &comp, .{ .key_down = .{ .key = .tab, .shift = false } });
        const f = (try app.handle(Many, &comp, .{ .frame = .{ .tick = @intCast(2 + i), .time_ms = 0 } })) orelse
            return error.MissingFrameOutput;
        defer if (f.json) |j| std.testing.allocator.free(j);
        last_focus = f.focus;
    }
    const final_focus = last_focus orelse return error.MissingFocus;
    try std.testing.expectEqual(button_ids[69], final_focus);
}

test "App: register records the root type name — the present() type guard" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();
    app.serialize_json = true;

    var counter: Counter = .{};
    _ = try app.register(Counter, &counter);

    // The guard's contract: frame()/handle()/present() must be called with
    // the SAME type register() stored — otherwise the type-erased vtable
    // would dispatch the registered type's draw on the caller's memory.
    // register() records the name here...
    try std.testing.expectEqualStrings(@typeName(Counter), app.root_type_name);

    // ...and present() refuses a mismatch (a runtime panic; a comptime
    // @compileError is impossible because the registered type lives only
    // in the runtime registry). Matching types compile and run normally.
    const out = try app.frame(Counter, &counter, 1, .{ .width = 800, .height = 600 });
    defer if (out.json) |j| std.testing.allocator.free(j);
    const json = out.json orelse return error.MissingFrameJson;
    try std.testing.expect(std.mem.indexOf(u8, json, "Count: 0") != null);
}

test "App: persistent registries stay bounded across many frames (flat memory)" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();

    const Comp = struct {
        const Self = @This();

        pub fn draw(self: *Self, ctx: *DrawCtx) !void {
            _ = self;
            _ = try ctx.column(.{});
            defer ctx.pop();
            _ = try ctx.button(.{ .label = "a" });
            _ = try ctx.button(.{ .label = "b" });
        }
    };
    var comp: Comp = .{};
    _ = try app.register(Comp, &comp);

    // 150 frames: the per-frame arenas retain their high-water, and the
    // persistent gpa state (component registry) must NOT grow — every
    // frame's component() puts overwrite the same 1 entry.
    var out: ?headless.FrameOutput = null;
    for (0..150) |i| {
        if (out) |o| if (o.json) |j| std.testing.allocator.free(j);
        out = try app.handle(Comp, &comp, .{ .frame = .{ .tick = @intCast(i + 1), .time_ms = @intCast(i * 16) } });
    }
    if (out) |o| if (o.json) |j| std.testing.allocator.free(j);

    // Exactly the root (id 1) — the two buttons are leaves, not components.
    try std.testing.expectEqual(@as(usize, 1), app.components.count());

    // The tree's node count is stable across frames (the last frame's tree
    // has the same shape as every other): column + 2 buttons + each
    // button's child label.
    const last = (try app.handle(Comp, &comp, .{ .frame = .{ .tick = 151, .time_ms = 2400 } })) orelse
        return error.MissingFrameOutput;
    defer if (last.json) |j| std.testing.allocator.free(j);
    try std.testing.expectEqual(@as(usize, 5), last.tree.nodes.items.len); // column + 2 buttons + 2 labels
}

test "App: deinit frees the component registry" {
    var app = App.init(std.testing.allocator);
    var counter: Counter = .{};
    _ = try app.register(Counter, &counter);
    // deinit without defer: the testing allocator's leak check after this
    // test is the assertion — a leak here fails the whole run.
    app.deinit();
}

test "present: press_alpha ramps over time and decays" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();

    const Comp = struct {
        const Self = @This();

        pub fn draw(self: *Self, ctx: *DrawCtx) !void {
            _ = self;
            _ = try ctx.column(.{ .gap = 8 });
            defer ctx.pop();
            _ = try ctx.button(.{ .label = "go" });
            _ = try ctx.label(.{ .text = "x" });
        }
    };
    var comp: Comp = .{};
    _ = try app.register(Comp, &comp);

    _ = try app.handle(Comp, &comp, .{ .resize = .{ .width = 200, .height = 200 } });
    const out1 = (try app.handle(Comp, &comp, .{ .frame = .{ .tick = 1, .time_ms = 0 } })) orelse
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
    _ = try app.handle(Comp, &comp, .{ .mouse_move = .{ .x = center[0], .y = center[1] } });
    _ = try app.handle(Comp, &comp, .{ .mouse_down = .{ .button = .left, .x = center[0], .y = center[1] } });
    const out2 = (try app.handle(Comp, &comp, .{ .frame = .{ .tick = 2, .time_ms = 100 } })) orelse
        return error.MissingFrameOutput;
    defer if (out2.json) |j| std.testing.allocator.free(j);
    try std.testing.expect(out2.pressed != null);
    try std.testing.expectApproxEqAbs(@as(f32, 0.632), out2.press_alpha, 0.05);
    try std.testing.expect(out2.press_alpha > 0.5 and out2.press_alpha < 0.8);

    // A second pole at the same dt: 0.632 + (1-0.632)*0.632 ≈ 0.865.
    const out3 = (try app.handle(Comp, &comp, .{ .frame = .{ .tick = 3, .time_ms = 200 } })) orelse
        return error.MissingFrameOutput;
    defer if (out3.json) |j| std.testing.allocator.free(j);
    try std.testing.expectApproxEqAbs(@as(f32, 0.865), out3.press_alpha, 0.05);
    try std.testing.expect(out3.press_alpha > 0.8);

    // Release: the target drops to 0 and press_alpha decays one pole
    // toward it: 0.865 * exp(-100/100) ≈ 0.318.
    _ = try app.handle(Comp, &comp, .{ .mouse_up = .{ .button = .left, .x = center[0], .y = center[1] } });
    const out4 = (try app.handle(Comp, &comp, .{ .frame = .{ .tick = 4, .time_ms = 300 } })) orelse
        return error.MissingFrameOutput;
    defer if (out4.json) |j| std.testing.allocator.free(j);
    try std.testing.expectApproxEqAbs(@as(f32, 0.318), out4.press_alpha, 0.05);
    try std.testing.expect(out4.press_alpha < 0.35);

    // The pointer leaves the window: hover_alpha (ramped to ≈0.811 while
    // hovering, tau 180ms) decays one pole toward 0: ≈0.465 — the fade
    // must still be mid-flight, not snapped.
    _ = try app.handle(Comp, &comp, .{ .mouse_leave = {} });
    const out5 = (try app.handle(Comp, &comp, .{ .frame = .{ .tick = 5, .time_ms = 400 } })) orelse
        return error.MissingFrameOutput;
    defer if (out5.json) |j| std.testing.allocator.free(j);
    try std.testing.expect(out5.hover_alpha > 0.3 and out5.hover_alpha < 0.6);

    // Move back over the button: re-enter (null → node) is NOT a reset —
    // the fade ramps from the decayed value: 0.465 + (1-0.465)*0.426 ≈
    // 0.693 (past the midpoint, still easing).
    _ = try app.handle(Comp, &comp, .{ .mouse_move = .{ .x = center[0], .y = center[1] } });
    const out6 = (try app.handle(Comp, &comp, .{ .frame = .{ .tick = 6, .time_ms = 500 } })) orelse
        return error.MissingFrameOutput;
    defer if (out6.json) |j| std.testing.allocator.free(j);
    try std.testing.expectApproxEqAbs(@as(f32, 0.693), out6.hover_alpha, 0.05);
    try std.testing.expect(out6.hover_alpha > 0.65);

    // Moving to a DIFFERENT node (still inside the window) resets the
    // fade again: the ring re-fades as the cursor travels between widgets.
    // The button's own label child is at the same position as the button —
    // scan for a label that is NOT inside the button's subtree.
    const label_center = blk: {
        const btn_id: Id = out6.hover orelse return error.MissingHoverTarget;
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
                var found: Id = .root;
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
    _ = try app.handle(Comp, &comp, .{ .mouse_move = .{ .x = label_center[0], .y = label_center[1] } });
    const out7 = (try app.handle(Comp, &comp, .{ .frame = .{ .tick = 7, .time_ms = 600 } })) orelse
        return error.MissingFrameOutput;
    defer if (out7.json) |j| std.testing.allocator.free(j);
    try std.testing.expect(!std.meta.eql(out7.hover, out6.hover));
    try std.testing.expectApproxEqAbs(@as(f32, 0.426), out7.hover_alpha, 0.05);

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
    var app = App.init(std.testing.allocator);
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
    _ = try app.register(Root, &root);
    _ = try app.frame(Root, &root, 1, .{ .width = 100, .height = 100 });
    const child_identity = ComponentId.child(.root, .{ .static = "child" });
    const root_entry = app.identity_registry.map.get(child_identity) orelse
        return error.MissingComponentIdentity;
    try std.testing.expectEqual(@as(u64, 1), root_entry.last_seen_frame);

    _ = try app.frame(Root, &root, 2, .{ .width = 100, .height = 100 });
    const entry = app.identity_registry.map.get(child_identity) orelse
        return error.MissingComponentIdentity;
    try std.testing.expectEqual(child_identity, ComponentId.child(.root, .{ .static = "child" }));
    try std.testing.expectEqual(@as(u64, 2), entry.last_seen_frame);
}

test "App: duplicate same-key sibling components are rejected" {
    var app = App.init(std.testing.allocator);
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
    _ = try app.register(Root, &root);
    try std.testing.expectError(
        error.DuplicateComponentIdentity,
        app.frame(Root, &root, 1, .{ .width = 100, .height = 100 }),
    );
}

test "App: component-scoped state survives a preceding sibling insertion" {
    var app = App.init(std.testing.allocator);
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
    _ = try app.register(Root, &root);
    _ = try app.frame(Root, &root, 1, .{ .width = 100, .height = 100 });
    try std.testing.expectEqual(@as(u32, 0), root.child.observed);

    root.insert_sibling = true;
    _ = try app.frame(Root, &root, 2, .{ .width = 100, .height = 100 });
    try std.testing.expectEqual(@as(u32, 1), root.child.observed);
}
