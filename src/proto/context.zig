//! Context — long-lived state shared across frames and windows.
//! Owns the GPU instance, the persistent widget state map, and
//! the frame counter. One Context per application.
//!
//! PROTOTYPE — throwaway design exploration.

const std = @import("std");
const noapi = @import("noapi");
const Id = @import("widget.zig").Id;
const InteractionState = @import("widget.zig").InteractionState;
const Key = @import("widget.zig").Key;
const KeyMods = @import("widget.zig").KeyMods;

/// Aggregated per-frame input state.
/// Lives in Context so it persists across frames (needed for
/// active/focus tracking) but is updated each frame by
/// dispatchEvents().
pub const InputState = struct {
    /// Current mouse position in window client coordinates.
    mouse_x: f32 = 0,
    mouse_y: f32 = 0,

    /// Mouse button currently held, or null.
    held_button: ?@import("widget.zig").MouseButton = null,

    /// ID of the widget that received mouse_down (track for release).
    active_id: ?Id = null,

    /// ID of the widget under the cursor (hot).
    hot_id: ?Id = null,

    /// ID of the keyboard-focused widget.
    focus_id: ?Id = null,

    /// Frame counter for click detection (double-click timing).
    last_click_frame: u64 = 0,
    last_click_button: ?@import("widget.zig").MouseButton = null,

    /// True when the active widget is dragged (mouse moved > threshold while held).
    dragging: bool = false,
};

/// Per-widget animation tuning. Configurable per widget type or globally.
pub const AnimConfig = struct {
    /// Lerp factor per frame for hot_t (0..1).
    hot_speed: f32 = 0.15,
    /// Lerp factor per frame for active_t.
    active_speed: f32 = 0.15,
    /// Lerp factor per frame for scroll_t (scroll animation progress).
    scroll_speed: f32 = 0.10,
};

/// Stable state retained across frames for a single widget.
pub const WidgetState = struct {
    /// Frame this state was last touched. Evict if stale.
    last_frame: u64,

    /// Interaction state machine.
    interaction: InteractionState = .inactive,

    /// Animation progress (0→1) for hot state.
    hot_t: f32 = 0,

    /// Animation progress (0→1) for active/pressed state.
    active_t: f32 = 0,

    /// Scroll offset for scrollable widgets.
    scroll_offset: f32 = 0,

    /// Scroll animation progress (0→1, used for smooth-scroll transitions).
    scroll_t: f32 = 1.0,

    /// Generic user data slot.
    user_data: u64 = 0,

    /// Per-state animation config (can be set once on first frame).
    anim: AnimConfig = .{},

    // ── Event state (set by processFrameAdvanceEvents, consumed by widgets) ──

    /// True for one frame after a click completes (down→up on same widget).
    clicked: bool = false,
    /// The frame when `clicked` was set.
    clicked_frame: u64 = 0,

    /// Last key pressed while this widget was focused (one-shot).
    key_pressed: ?Key = null,
    /// Last key released while this widget was focused.
    key_released: ?Key = null,
    /// Modifier state when key_pressed was set.
    key_mods: KeyMods = .{},
    /// Last text input codepoint (one-shot).
    text_codepoint: ?u21 = null,

    /// Advance animation values by one frame.
    /// Called by `processFrameAdvanceEvents` after layout completes.
    pub fn advanceAnim(self: *@This(), is_hot: bool, is_active: bool) void {
        const target_hot: f32 = if (is_hot or is_active) 1.0 else 0.0;
        self.hot_t += (target_hot - self.hot_t) * self.anim.hot_speed;

        const target_active: f32 = if (is_active) 1.0 else 0.0;
        self.active_t += (target_active - self.active_t) * self.anim.active_speed;

        // Scroll animation: if scroll_t < 1, animate toward 1
        if (self.scroll_t < 1.0) {
            self.scroll_t += (1.0 - self.scroll_t) * self.anim.scroll_speed;
            if (self.scroll_t > 0.999) self.scroll_t = 1.0;
        }
    }
};

/// Application-global context. Created once, passed to all Windows.
pub const Context = struct {
    gpu: noapi.Gpu,
    state_map: std.AutoHashMap(Id, WidgetState),
    frame_count: u64 = 0,
    gpa: std.mem.Allocator,

    /// Per-frame input state — updated by dispatchEvents().
    input_state: InputState = .{},

    pub fn init(gpa: std.mem.Allocator, gpu: noapi.Gpu) @This() {
        return .{
            .gpu = gpu,
            .state_map = std.AutoHashMap(Id, WidgetState).init(gpa),
            .gpa = gpa,
        };
    }

    pub fn deinit(self: *@This()) void {
        self.state_map.deinit();
        self.gpu.deinit();
    }

    /// Get or create persistent state for a widget ID.
    /// Returns null if the widget wasn't active last frame.
    pub fn getOrCreateState(self: *@This(), id: Id) !*WidgetState {
        const entry = try self.state_map.getOrPut(id);
        if (!entry.found_existing) {
            entry.value_ptr.* = .{ .last_frame = self.frame_count };
        }
        entry.value_ptr.last_frame = self.frame_count;
        return entry.value_ptr;
    }

    /// Evict states that haven't been touched in N frames.
    pub fn gcStates(self: *@This(), max_age: u64) void {
        var it = self.state_map.iterator();
        while (it.next()) |entry| {
            if (self.frame_count - entry.value_ptr.last_frame > max_age) {
                _ = self.state_map.remove(entry.key_ptr.*);
            }
        }
    }
};
