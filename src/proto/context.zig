//! Context — long-lived state shared across frames and windows.
//! Owns the GPU instance, the persistent widget state map, and
//! the frame counter. One Context per application.
//!
//! PROTOTYPE — throwaway design exploration.

const std = @import("std");
const noapi = @import("noapi");
const Widget = @import("widget.zig").Widget;
const Id = @import("widget.zig").Id;

/// Stable state retained across frames for a single widget.
pub const WidgetState = struct {
    /// Frame this state was last touched. Evict if stale.
    last_frame: u64,

    /// Animation progress (0→1) for hot state.
    hot_t: f32 = 0,

    /// Animation progress (0→1) for active/pressed state.
    active_t: f32 = 0,

    /// Scroll offset for scrollable widgets.
    scroll_offset: f32 = 0,

    /// Generic user data slot.
    user_data: u64 = 0,
};

/// Application-global context. Created once, passed to all Windows.
pub const Context = struct {
    gpu: noapi.Gpu,
    state_map: std.AutoHashMap(Id, WidgetState),
    frame_count: u64 = 0,
    gpa: std.mem.Allocator,

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
    pub fn getOrCreateState(self: *@This(), id: Id) *WidgetState {
        const entry = self.state_map.getOrPut(id) catch @panic("OOM");
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
