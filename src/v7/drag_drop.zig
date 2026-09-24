//! Internal drag ownership and dispatch. Payload storage uses a caller-owned long-lived allocator.
//! Native file offers are a separate host capability and are never converted to typed payloads here.
const std = @import("std");
const WidgetId = @import("id.zig").WidgetId;
const PointerId = @import("event.zig").PointerId;
const WidgetTree = @import("widget.zig").WidgetTree;
const input = @import("input.zig");

pub const PayloadView = struct {
    ptr: *const anyopaque,
    marker: *const u8,

    /// Borrow only for the duration of a handler invocation.
    pub fn get(self: PayloadView, comptime T: type) ?*const T {
        if (self.marker != typeMarker(T)) return null;
        return @ptrCast(@alignCast(self.ptr));
    }
};

pub const Handler = struct {
    user: *anyopaque,
    enter: ?*const fn (*anyopaque, WidgetId, PayloadView) void = null,
    move: ?*const fn (*anyopaque, WidgetId, PayloadView) void = null,
    leave: ?*const fn (*anyopaque, WidgetId, PayloadView) void = null,
    can_drop: ?*const fn (*anyopaque, WidgetId, PayloadView) bool = null,
    drop: ?*const fn (*anyopaque, WidgetId, PayloadView) void = null,
    cancel: ?*const fn (*anyopaque, WidgetId, PayloadView) void = null,
};

const Active = struct {
    gpa: std.mem.Allocator,
    payload: *anyopaque,
    marker: *const u8,
    release: *const fn (std.mem.Allocator, *anyopaque) void,
    source: WidgetId,
    pointer: PointerId,
    start: [2]f32,
    threshold: f32,
    dragging: bool = false,
    over: ?WidgetId = null,
    preview: ?WidgetId = null,
    serial: u64,

    fn view(self: *const Active) PayloadView {
        return .{ .ptr = self.payload, .marker = self.marker };
    }
};

pub const Manager = struct {
    active: ?Active = null,
    serial: u64 = 0,

    pub const Error = error{ AlreadyDragging, InvalidThreshold } || std.mem.Allocator.Error;

    /// `value` moves to allocated storage; any `T.deinit(*T)` runs exactly once on retirement.
    pub fn begin(
        self: *Manager,
        comptime T: type,
        gpa: std.mem.Allocator,
        source: WidgetId,
        pointer: PointerId,
        start: [2]f32,
        threshold: f32,
        value: T,
    ) Error!void {
        if (self.active != null) return error.AlreadyDragging;
        if (!std.math.isFinite(threshold) or threshold < 0 or
            !std.math.isFinite(start[0]) or !std.math.isFinite(start[1]))
        {
            return error.InvalidThreshold;
        }
        const payload = try gpa.create(T);
        self.serial +%= 1;
        payload.* = value;
        self.active = .{
            .gpa = gpa,
            .payload = payload,
            .marker = typeMarker(T),
            .release = struct {
                fn destroy(allocator: std.mem.Allocator, raw: *anyopaque) void {
                    const typed: *T = @ptrCast(@alignCast(raw));
                    if (comptime switch (@typeInfo(T)) {
                        .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(T, "deinit"),
                        else => false,
                    }) typed.deinit();
                    allocator.destroy(typed);
                }
            }.destroy,
            .source = source,
            .pointer = pointer,
            .start = start,
            .serial = self.serial,
            .threshold = threshold,
        };
    }

    /// A keyed preview may be rendered in an escape overlay; it is never a drop target.
    pub fn setPreview(self: *Manager, pointer: PointerId, preview_key: WidgetId) bool {
        const active = if (self.active) |*state| state else return false;
        if (!std.meta.eql(active.pointer, pointer)) return false;
        active.preview = preview_key;
        return true;
    }

    pub fn preview(self: *const Manager) ?WidgetId {
        const active = self.active orelse return null;
        return if (active.dragging) active.preview else null;
    }

    pub fn pointerMove(
        self: *Manager,
        tree: *const WidgetTree,
        pointer: PointerId,
        pos: [2]f32,
        hit: ?WidgetId,
        handler: Handler,
    ) void {
        const active = if (self.active) |*state| state else return;
        if (!std.meta.eql(active.pointer, pointer)) return;
        if (!enabled(tree, active.source) or !std.math.isFinite(pos[0]) or
            !std.math.isFinite(pos[1]))
        {
            self.cancel(pointer, handler);
            return;
        }
        if (!active.dragging) {
            const dx = pos[0] - active.start[0];
            const dy = pos[1] - active.start[1];
            if (@sqrt(dx * dx + dy * dy) < active.threshold) return;
            active.dragging = true;
        }
        const next: ?WidgetId = if (hit) |id| blk: {
            if (active.preview) |preview_key| {
                if (preview_key.eql(id)) break :blk null;
            }
            break :blk if (enabled(tree, id)) id else null;
        } else null;
        if (same(active.over, next)) {
            if (next) |id| {
                if (handler.move) |callback| callback(handler.user, id, active.view());
            }
            return;
        }
        if (active.over) |old| {
            const serial = active.serial;
            const view = active.view();
            active.over = null;
            if (handler.leave) |callback| callback(handler.user, old, view);
            const retained = if (self.active) |*state| state else return;
            if (retained.serial != serial) return;
        }
        if (next) |id| {
            const retained = if (self.active) |*state| state else return;
            retained.over = id;
            if (handler.enter) |callback| callback(handler.user, id, retained.view());
        }
    }

    /// A release over the current eligible target commits only if can_drop accepts it.
    /// Even if rejected, all callbacks finish before the payload is released once.
    pub fn pointerRelease(
        self: *Manager,
        tree: *const WidgetTree,
        pointer: PointerId,
        hit: ?WidgetId,
        handler: Handler,
    ) bool {
        const current = self.active orelse return false;
        if (!std.meta.eql(current.pointer, pointer)) return false;
        self.active = null;
        defer current.release(current.gpa, current.payload);
        const view = current.view();
        if (current.dragging and enabled(tree, current.source)) {
            if (current.over) |target| {
                if (hit) |released| {
                    if (target.eql(released) and enabled(tree, target)) {
                        const accepts = if (handler.can_drop) |callback|
                            callback(handler.user, target, view)
                        else
                            false;
                        if (accepts) {
                            if (handler.drop) |commit| {
                                commit(handler.user, target, view);
                                return true;
                            }
                        }
                    }
                }
            }
        }
        if (current.over) |target| {
            if (handler.leave) |callback| callback(handler.user, target, view);
        }
        if (handler.cancel) |callback| callback(handler.user, current.source, view);
        return false;
    }

    pub fn cancel(self: *Manager, pointer: PointerId, handler: Handler) void {
        const current = self.active orelse return;
        if (!std.meta.eql(current.pointer, pointer)) return;
        self.active = null;
        defer current.release(current.gpa, current.payload);
        const view = current.view();
        if (current.over) |target| {
            if (handler.leave) |callback| callback(handler.user, target, view);
        }
        if (handler.cancel) |callback| callback(handler.user, current.source, view);
    }

    /// Run after frame publication. Retired sources cancel; retired targets leave.
    pub fn reconcile(self: *Manager, tree: *const WidgetTree, handler: Handler) void {
        const active = if (self.active) |*state| state else return;
        if (!enabled(tree, active.source)) {
            self.cancel(active.pointer, handler);
            return;
        }
        if (active.preview) |preview_key| {
            if (!enabled(tree, preview_key)) active.preview = null;
        }
        if (active.over) |target| {
            if (!enabled(tree, target)) {
                const view = active.view();
                active.over = null;
                if (handler.leave) |callback| callback(handler.user, target, view);
            }
        }
    }

    /// Call `cancel` first to emit a cancellation notification on window leave/focus loss.
    pub fn deinit(self: *Manager) void {
        if (self.active) |state| state.release(state.gpa, state.payload);
        self.active = null;
        self.* = undefined;
    }
};

fn typeMarker(comptime T: type) *const u8 {
    const PerType = struct {
        const value_type = T;
        var marker: u8 = 0;
    };
    return &PerType.marker;
}
fn enabled(tree: *const WidgetTree, id: WidgetId) bool {
    const node = tree.frameNode(id) orelse return false;
    return input.isEnabled(tree, node);
}
fn same(a: ?WidgetId, b: ?WidgetId) bool {
    if (a) |first| {
        if (b) |second| return first.eql(second);
        return false;
    }
    return b == null;
}
