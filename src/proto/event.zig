//! Event system — OS input translation, hit-testing, and
//! immediate-mode widget interaction dispatch.
//!
//! Architecture
//! ────────────
//! 1. Window.pollEvents() translates SDL3 events → our Event tagged
//!    union and stores them in a per-frame queue.
//! 2. The user builds the widget tree (DrawCtx.column/button/...).
//! 3. `layoutAndRender` computes final rects for every widget.
//! 4. `dispatchEvents()` replays the event queue against the laid-out
//!    widget tree:
//!     - mouse_move   → hit-test → set hot state (+ cursor change)
//!     - mouse_down   → hit-test → set active + focus
//!     - mouse_up     → if was active, mark clicked=true for one frame
//!     - mouse_wheel  → hit-test → forward scroll to hovered widget
//!     - key_down/up  → route to focused widget
//! 5. `processFrameAdvanceEvents()` walks the tree after dispatch,
//!    determines hot/active/focus states, and advances animations
//!    (hot_t, active_t, scroll_t) via WidgetState.advanceAnim().
//! 6. Next frame: widget constructors read WidgetState (isHot, wasClicked)
//!    to adjust colors, trigger actions, etc.
//!
//! Headless / recorded-trace mode:
//!   Replace SDL3 poll loop with EventReader over a file/network stream.
//!   Same dispatch path — just inject Event values from a different source.
//!
//! PROTOTYPE — design exploration. Not wired into the renderer yet.
//!
//! TODO: SDL3 → Event translation in window.zig pollEvents().
//! TODO: hot-reload: preserve focus_id across recompiles; gcStates
//!       evicts stale entries after reload.

const std = @import("std");
const Widget = @import("widget.zig").Widget;
const Id = @import("widget.zig").Id;
const MouseButton = @import("widget.zig").MouseButton;
const Key = @import("widget.zig").Key;
const KeyMods = @import("widget.zig").KeyMods;
const Context = @import("context.zig").Context;

// ─── Event Tagged Union ───────────────────────────────

/// A single input event, translated from SDL3.
/// Pure data — no pointers, no allocator dependencies.
/// Copyable, serializable, replayable.
pub const Event = union(enum) {
    // ── Mouse ────────────────────────────────────────
    mouse_move: struct {
        x: f32,
        y: f32,
        rel_x: f32,
        rel_y: f32,
    },
    mouse_button_down: struct {
        button: MouseButton,
        x: f32,
        y: f32,
        clicks: u32, // 1 = single, 2 = double, etc.
    },
    mouse_button_up: struct {
        button: MouseButton,
        x: f32,
        y: f32,
        clicks: u32,
    },
    mouse_wheel: struct {
        scroll_x: f32,
        scroll_y: f32,
    },

    // ── Keyboard ─────────────────────────────────────
    key_down: struct {
        key: Key,
        mods: KeyMods,
        repeat: bool,
    },
    key_up: struct {
        key: Key,
        mods: KeyMods,
    },
    text_input: struct {
        codepoint: u21,
    },

    // ── Window ───────────────────────────────────────
    window_close: struct {
        win_id: u32,
    },
    window_resized: struct {
        win_id: u32,
        width: u32,
        height: u32,
    },
    window_focus: struct {
        win_id: u32,
        focused: bool,
    },

    // ── Custom / app-defined ─────────────────────────
    custom: struct {
        id: u64,
        data: u64,
    },
};

// ─── Hit-testing ──────────────────────────────────────

/// Result of hit-testing the widget tree at a point.
pub const HitResult = struct {
    /// Widget ID of the deepest widget containing the point.
    widget_id: Id,
    /// Pointer to the widget (valid for the current frame only).
    widget: *Widget,
    /// Nesting depth (0 = root). Higher = deeper.
    depth: u32,
};

/// Walk the widget tree in reverse-order (topmost-last) and return the
/// deepest *interactive* widget containing (x, y).
///
/// Uses a stack-based DFS. We reverse the result so the last widget
/// drawn (topmost in z-order) wins.
pub fn hitTest(root: *Widget, x: f32, y: f32) ?HitResult {
    // ── Phase 1: collect all widgets containing point ──
    var hits: [256]HitResult = undefined;
    var hit_count: u32 = 0;

    var stack: [512]*Widget = undefined;
    var sp: u32 = 0;
    var depths: [512]u32 = undefined;

    stack[sp] = root;
    depths[sp] = 0;
    sp += 1;

    while (sp > 0 and hit_count < hits.len) {
        sp -= 1;
        const w = stack[sp];
        const d = depths[sp];

        // Check containment
        if (x >= w.rect.x and x <= w.rect.x + w.rect.w and
            y >= w.rect.y and y <= w.rect.y + w.rect.h)
        {
            hits[hit_count] = .{
                .widget_id = w.id,
                .widget = w,
                .depth = d,
            };
            hit_count += 1;
        }

        // Push children
        if (w.children()) |kids| {
            var i: usize = kids.len;
            while (i > 0) {
                i -= 1;
                stack[sp] = kids[i];
                depths[sp] = d + 1;
                sp += 1;
            }
        }
    }

    if (hit_count == 0) return null;

    // ── Phase 2: pick the deepest hit ≡ last in reverse DFS ──
    // Since we pushed children in reverse order, the last entry
    // in hits is the rightmost leaf — which is also the topmost
    // in the render order.
    return hits[hit_count - 1];
}

// ─── Dispatch Engine ──────────────────────────────────

/// State machine transitions for a single widget interaction.
///
/// ```
///          mouse enter           mouse_down on self
/// INACTIVE ──────────→ HOT ───────────────────────→ ACTIVE
///   ↑                     ↑                              │
///   │ mouse leave         │ mouse_down on other          │ mouse_up
///   └─────────────────────┘◄─────────────────────────────┘
///                          ←── active_id released ──────┘
/// ```
///
/// Focus is tracked independently:
///   mouse_down on widget → focus_id = widget.id
///   tab                  → focus_id = next focusable widget

/// Translate SDL3 events to our Event type and dispatch them against
/// the laid-out widget tree.
///
/// Called once per frame, AFTER `layoutAndRender()` so every widget
/// has its final rect.
pub fn dispatchEvents(ctx: *Context, root: *Widget, events: []const Event) void {
    const input = &ctx.input_state;
    const frame = ctx.frame_count;

    // ── 1. Process raw events ────────────────────────────
    for (events) |ev| {
        switch (ev) {
            .mouse_move => |mm| {
                input.mouse_x = mm.x;
                input.mouse_y = mm.y;
            },
            .mouse_button_down => |mb| {
                if (mb.button == .left) {
                    input.held_button = mb.button;

                    // Hit-test for press target
                    const hit = hitTest(root, mb.x, mb.y);
                    const target_id = if (hit) |h| h.widget_id else null;

                    input.active_id = target_id;

                    // Click-to-focus
                    if (target_id) |id| {
                        input.focus_id = id;
                    }

                    input.dragging = false;
                }
            },
            .mouse_button_up => |mb| {
                if (mb.button == .left) {
                    // ── Click detection ─────────────────
                    // If we released over the same widget we pressed on,
                    // and it wasn't a drag, that's a click.
                    const hit = hitTest(root, mb.x, mb.y);
                    const release_id = if (hit) |h| h.widget_id else null;

                    if (input.active_id != null and input.active_id == release_id and !input.dragging) {
                        // Mark clicked in WidgetState
                        if (ctx.getOrCreateState(input.active_id.?)) |state| {
                            state.clicked = true;
                            state.clicked_frame = frame;
                        } else |_| {}
                    }

                    input.active_id = null;
                    input.held_button = null;
                    input.dragging = false;
                }
            },
            .mouse_wheel => |mw| {
                // Route scroll to hovered widget
                const hit = hitTest(root, input.mouse_x, input.mouse_y);
                if (hit) |h| {
                    if (ctx.getOrCreateState(h.widget_id)) |state| {
                        state.scroll_offset += mw.scroll_y * 30.0; // 30px per notch
                    } else |_| {}
                }
            },
            .key_down => |kd| {
                // Tab → cycle focus
                if (kd.key == .tab) {
                    cycleFocus(ctx, root, kd.mods.shift);
                    continue;
                }
                // Escape → clear focus
                if (kd.key == .escape) {
                    input.focus_id = null;
                    continue;
                }
                // Route to focused widget (stored in WidgetState)
                if (input.focus_id) |fid| {
                    if (ctx.getOrCreateState(fid)) |state| {
                        state.key_pressed = kd.key;
                        state.key_mods = kd.mods;
                    } else |_| {}
                }
            },
            .key_up => |ku| {
                // Route key-up to focused widget
                if (input.focus_id) |fid| {
                    if (ctx.getOrCreateState(fid)) |state| {
                        state.key_released = ku.key;
                    } else |_| {}
                }
            },
            .text_input => |ti| {
                // Route text to focused widget
                if (input.focus_id) |fid| {
                    if (ctx.getOrCreateState(fid)) |state| {
                        state.text_codepoint = ti.codepoint;
                    } else |_| {}
                }
            },
            .window_close => |wc| {
                _ = wc; // handled in pollEvents via should_close
            },
            .window_resized => |wr| {
                _ = wr; // handled in pollEvents via gpu_window.notifyResize
            },
            .window_focus => |wf| {
                if (!wf.focused) {
                    // Release all interaction states on focus loss
                    input.active_id = null;
                    input.held_button = null;
                    input.dragging = false;
                    // Keep focus_id — restore on re-focus
                }
            },
            .custom => |ce| {
                _ = ce;
                // Custom events route to the root widget's user_data.
                // App can define its own event handling.
            },
        }
    }

    // ── 2. Update hot state from final mouse position ────
    const hit = hitTest(root, input.mouse_x, input.mouse_y);
    input.hot_id = if (hit) |h| h.widget_id else null;

    // ── 3. Process frame advance events (interaction + animation) ──
    processFrameAdvanceEvents(ctx, root, input);
}

/// Walk the widget tree after event dispatch to update interaction
/// state machines and advance per-frame animations.
///
/// Called once per frame, AFTER `dispatchEvents()` and AFTER
/// `layoutAndRender()` so every widget has final rects.
///
/// For each widget:
///   1. Determine interaction state from InputState (hot/active/focus)
///   2. Call `state.advanceAnim(is_hot, is_active)` for smooth lerp
///
/// Separated from `dispatchEvents` so it can be called independently
/// in headless mode or replayed traces.
pub fn processFrameAdvanceEvents(ctx: *Context, root: *Widget, input: *const @import("context.zig").InputState) void {
    var stack: [512]*Widget = undefined;
    var sp: u32 = 0;
    stack[sp] = root;
    sp += 1;

    while (sp > 0) {
        sp -= 1;
        const w = stack[sp];

        if (ctx.getOrCreateState(w.id)) |state| {
            const is_hot = input.hot_id == w.id;
            const is_active = input.active_id == w.id;
            const is_focused = input.focus_id == w.id;

            if (is_active) {
                state.interaction = .active;
            } else if (is_hot) {
                state.interaction = .hot;
            } else if (is_focused) {
                state.interaction = .focused;
            } else {
                if (state.interaction != .inactive) {
                    state.interaction = .inactive;
                }
            }

            state.advanceAnim(is_hot, is_active);
        } else |_| {}

        if (w.children()) |kids| {
            var i: usize = kids.len;
            while (i > 0) {
                i -= 1;
                stack[sp] = kids[i];
                sp += 1;
            }
        }
    }
}

/// Simple linear focus traversal: find all focusable widgets in tree
/// and move focus forward (or backward with shift).
fn cycleFocus(ctx: *Context, root: *Widget, reverse: bool) void {
    var focusable: [256]Id = undefined;
    var count: u32 = 0;

    var stack: [512]*Widget = undefined;
    var sp: u32 = 0;
    stack[sp] = root;
    sp += 1;

    while (sp > 0 and count < focusable.len) {
        sp -= 1;
        const w = stack[sp];

        // All interactive widgets are focusable.
        // Non-interactive containers are skipped.
        switch (w.kind) {
            .button, .slider => {
                focusable[count] = w.id;
                count += 1;
            },
            else => {},
        }

        if (w.children()) |kids| {
            var i: usize = kids.len;
            while (i > 0) {
                i -= 1;
                stack[sp] = kids[i];
                sp += 1;
            }
        }
    }

    if (count == 0) return;

    const current = ctx.input_state.focus_id;
    const start: usize = if (current) |fid| blk: {
        // Find current focus index
        for (focusable[0..count], 0..) |f, i| {
            if (f == fid) break :blk i;
        }
        break :blk std.math.maxInt(usize);
    } else std.math.maxInt(usize);

    const next = if (reverse) blk: {
        if (start == 0 or start == std.math.maxInt(usize)) break :blk count - 1;
        break :blk start - 1;
    } else blk: {
        if (start < count - 1) break :blk start + 1;
        break :blk 0;
    };

    ctx.input_state.focus_id = focusable[next];
}

// ─── Query helpers (called by widget constructors) ──

/// Returns true if the widget is hovered this frame.
pub fn isHot(state: *const @import("context.zig").WidgetState) bool {
    return state.interaction == .hot or state.interaction == .active;
}

/// Returns true if the widget is pressed this frame.
pub fn isActive(state: *const @import("context.zig").WidgetState) bool {
    return state.interaction == .active;
}

/// Returns true if the widget was just clicked this frame.
/// Consumed by widget constructor — resets to false after read.
pub fn wasClicked(state: *@import("context.zig").WidgetState) bool {
    const result = state.clicked;
    state.clicked = false; // one-shot
    return result;
}

/// Returns true if the widget has keyboard focus.
pub fn isFocused(state: *const @import("context.zig").WidgetState) bool {
    return state.interaction == .focused;
}

// ─── Recorded Trace (headless / testing) ──────────────

/// Reader interface for injecting events from a non-SDL source.
pub const EventReader = struct {
    buf: []const Event,
    pos: usize,

    pub fn read(self: *@This()) ?Event {
        if (self.pos >= self.buf.len) return null;
        const ev = self.buf[self.pos];
        self.pos += 1;
        return ev;
    }
};

// ─── Tests ────────────────────────────────────────────

const testing = std.testing;

fn testId(n: usize) Id {
    return @enumFromInt(n + 100);
}

test "hitTest: returns null for empty tree" {
    var root = Widget{ .id = Id.zero, .sizing = .{}, .kind = .{ .label = .{ .text = "" } } };
    root.rect = .{ .x = 0, .y = 0, .w = 100, .h = 100 };
    const result = hitTest(&root, 200, 200);
    try testing.expect(result == null);
}

test "hitTest: finds widget at point" {
    var root = Widget{ .id = Id.root, .sizing = .{}, .kind = .{ .label = .{ .text = "" } } };
    root.rect = .{ .x = 0, .y = 0, .w = 100, .h = 100 };
    const result = hitTest(&root, 50, 50);
    try testing.expect(result != null);
    try testing.expectEqual(Id.root, result.?.widget_id);
}

test "hitTest: picks deepest widget" {
    const child_id = testId(0);
    var child = Widget{ .id = child_id, .sizing = .{}, .kind = .{ .button = .{ .label = "" } } };
    child.rect = .{ .x = 10, .y = 10, .w = 30, .h = 30 };

    var root = Widget{ .id = Id.root, .sizing = .{}, .kind = .{ .column = .{ .children = &.{&child} } } };
    root.rect = .{ .x = 0, .y = 0, .w = 100, .h = 100 };

    const result = hitTest(&root, 25, 25);
    try testing.expect(result != null);
    try testing.expectEqual(child_id, result.?.widget_id);
}

test "KeyMods: default is empty" {
    const mods = KeyMods{};
    try testing.expect(!mods.shift);
    try testing.expect(!mods.ctrl);
    try testing.expect(!mods.alt);
    try testing.expect(!mods.gui);
}

test "Event: is plain-data union (no dangling ptrs)" {
    const ev = Event{ .mouse_move = .{ .x = 100, .y = 200, .rel_x = 0, .rel_y = 0 } };
    try testing.expectEqual(@as(f32, 100), ev.mouse_move.x);
}

test "EventReader: replays event sequence" {
    const events = [_]Event{
        .{ .mouse_move = .{ .x = 10, .y = 20, .rel_x = 0, .rel_y = 0 } },
        .{ .mouse_button_down = .{ .button = .left, .x = 10, .y = 20, .clicks = 1 } },
        .{ .mouse_button_up = .{ .button = .left, .x = 10, .y = 20, .clicks = 1 } },
    };
    var reader = EventReader{ .buf = &events, .pos = 0 };
    try testing.expect(reader.read() != null);
    try testing.expect(reader.read() != null);
    try testing.expect(reader.read() != null);
    try testing.expect(reader.read() == null);
}
