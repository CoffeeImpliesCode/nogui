//! Tooltip hover state. The Session W05 UI task service owns the timer: schedule
//! `deadline().at_ns`, pass its token to `expire`, and cancel its task on a new deadline.
const std = @import("std");
const Clock = @import("clock.zig").Clock;
const widget = @import("widget.zig");
const input = @import("input.zig");
const WidgetId = @import("id.zig").WidgetId;

pub const Deadline = struct { token: u64, at_ns: i96 };
const Entry = struct {
    owner: WidgetId,
    description: []u8,
    hoverable: bool,
    hovered_owner: bool = true,
    hovered_tooltip: bool = false,
    visible: bool = false,
    deadline_ns: ?i96,
    bounds: ?widget.Rect = null,
};

pub const Manager = struct {
    gpa: std.mem.Allocator,
    clock: Clock,
    active: ?Entry = null,
    generation: u64 = 0,

    pub fn init(gpa: std.mem.Allocator, clock: Clock) Manager {
        return .{ .gpa = gpa, .clock = clock };
    }

    pub fn deinit(self: *Manager) void {
        self.cancel();
        self.* = undefined;
    }

    /// A repeated hover on the same owner preserves its existing deadline.
    /// Descriptions are copied because the caller's frame arena may retire first.
    pub fn hover(
        self: *Manager,
        owner: WidgetId,
        description: []const u8,
        delay_ns: u64,
        hoverable: bool,
    ) std.mem.Allocator.Error!void {
        if (self.active) |*existing| {
            if (existing.owner.eql(owner) and existing.hoverable == hoverable and
                std.mem.eql(u8, existing.description, description))
            {
                existing.hovered_owner = true;
                existing.hovered_tooltip = false;
                return;
            }
        }
        const owned = try self.gpa.dupe(u8, description);
        self.cancel();
        self.generation +%= 1;
        self.active = .{
            .owner = owner,
            .description = owned,
            .hoverable = hoverable,
            .deadline_ns = self.clock.now() +| @as(i96, delay_ns),
        };
    }

    /// The caller presents this deadline to Session.scheduleUi with a weak owner.
    /// Replacing or removing an owner invalidates old callbacks by token.
    pub fn deadline(self: *const Manager) ?Deadline {
        const entry = self.active orelse return null;
        const at_ns = entry.deadline_ns orelse return null;
        return .{ .token = self.generation, .at_ns = at_ns };
    }

    /// Invoke from a delivered W05 UI timer, never from an in-progress frame.
    /// Returns true only for a newly visible tooltip; request a frame then.
    pub fn expire(self: *Manager, token: u64, tree: *const widget.WidgetTree) bool {
        const entry = if (self.active) |*current| current else return false;
        if (token != self.generation) return false;
        if (!eligible(tree, entry.owner) or !entry.hovered_owner) {
            self.cancel();
            return false;
        }
        const deadline_ns = entry.deadline_ns orelse return false;
        if (self.clock.now() < deadline_ns) return false;
        entry.deadline_ns = null;
        entry.visible = true;
        return true;
    }

    /// Pass the resolved overlay bounds each frame so the content itself can be hovered.
    pub fn setBounds(self: *Manager, rect: widget.Rect) void {
        if (self.active) |*entry| {
            entry.bounds = if (std.math.isFinite(rect.x) and std.math.isFinite(rect.y) and
                std.math.isFinite(rect.w) and std.math.isFinite(rect.h) and
                rect.w > 0 and rect.h > 0) rect else null;
        }
    }

    pub fn pointerMove(self: *Manager, owner_hit: ?WidgetId, point: [2]f32) void {
        const entry = if (self.active) |*current| current else return;
        if (owner_hit) |id| {
            if (id.eql(entry.owner)) {
                entry.hovered_owner = true;
                entry.hovered_tooltip = false;
                return;
            }
        }
        if (entry.visible and entry.hoverable) {
            if (entry.bounds) |bounds| {
                if (contains(bounds, point)) {
                    entry.hovered_owner = false;
                    entry.hovered_tooltip = true;
                    return;
                }
            }
        }
        self.cancel();
    }

    pub fn leaveOwner(self: *Manager, inside_tooltip: bool) void {
        const entry = if (self.active) |*current| current else return;
        if (entry.visible and entry.hoverable and inside_tooltip) {
            entry.hovered_owner = false;
            entry.hovered_tooltip = true;
            return;
        }
        self.cancel();
    }

    /// Keyboard/semantic description is present during the delay, not just after paint.
    pub fn descriptionFor(self: *const Manager, owner: WidgetId) ?[]const u8 {
        const entry = self.active orelse return null;
        return if (entry.owner.eql(owner)) entry.description else null;
    }

    pub fn visible(self: *const Manager) bool {
        const entry = self.active orelse return false;
        return entry.visible;
    }

    /// A hidden, disabled or recycled owner cancels its pending W05 deadline.
    pub fn reconcile(self: *Manager, tree: *const widget.WidgetTree) void {
        const entry = self.active orelse return;
        if (!eligible(tree, entry.owner)) self.cancel();
    }

    pub fn cancel(self: *Manager) void {
        if (self.active) |entry| {
            self.gpa.free(entry.description);
            self.active = null;
            self.generation +%= 1;
        }
    }
};

fn eligible(tree: *const widget.WidgetTree, id: WidgetId) bool {
    const node = tree.frameNode(id) orelse return false;
    return input.isEnabled(tree, node);
}
fn contains(rect: widget.Rect, point: [2]f32) bool {
    return point[0] >= rect.x and point[0] < rect.x + rect.w and
        point[1] >= rect.y and point[1] < rect.y + rect.h;
}
