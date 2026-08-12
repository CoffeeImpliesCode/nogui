//! Type-erased component dispatch: vtable + opaque receiver.
//! Per the prototype spec (notes/v7-prototype-spec.md §5).
//!
//! Every element of a UI — including the root — is a `Component(T)`
//! created with `Component.make(T, ptr)`. `draw` is mandatory; `onEvent`
//! and `deinit` are optional and detected via `@hasDecl`.
const std = @import("std");

const DrawCtx = @import("drawctx.zig").DrawCtx;
const Event = @import("event.zig").Event;
const WidgetTree = @import("widget.zig").WidgetTree;

/// Type-erased operations for a component of any concrete type T.
/// `deinit` takes the allocator first, then the opaque receiver: it frees
/// the component's internals and poisons the receiver; the OWNER of the
/// concrete allocation calls `allocator.destroy` after it returns.
pub const ComponentVTable = struct {
    draw: *const fn (*anyopaque, *DrawCtx) anyerror!void,
    on_event: ?*const fn (*anyopaque, *const Event) void,
    deinit: ?*const fn (std.mem.Allocator, *anyopaque) void,
};

/// A type-erased component: an opaque pointer plus its vtable.
pub const Component = struct {
    ptr: *anyopaque,
    vtable: *const ComponentVTable,

    /// Build a Component from a concrete type. T must declare
    /// `draw(self: *T, ctx: *DrawCtx) !void` (checked at comptime);
    /// `onEvent` and `deinit` are optional. The adapters cast the
    /// `*anyopaque` receiver back to `*T` and dispatch with `.auto`.
    pub fn make(comptime T: type, ptr: *T) Component {
        if (!@hasDecl(T, "draw")) {
            @compileError("Component type " ++ @typeName(T) ++ " must declare draw(self: *T, ctx: *DrawCtx) !void");
        }

        const Impl = struct {
            fn draw(p: *anyopaque, ctx: *DrawCtx) anyerror!void {
                const t: *T = @ptrCast(@alignCast(p));
                return @call(.auto, T.draw, .{ t, ctx });
            }
            fn onEvent(p: *anyopaque, ev: *const Event) void {
                const t: *T = @ptrCast(@alignCast(p));
                @call(.auto, T.onEvent, .{ t, ev });
            }
            fn deinit(allocator: std.mem.Allocator, p: *anyopaque) void {
                const t: *T = @ptrCast(@alignCast(p));
                @call(.auto, T.deinit, .{ t, allocator });
                t.* = undefined; // poison last; the allocation is still live
            }
        };

        // All fields are comptime-known (fn pointers + @hasDecl), so the
        // const is hoisted to static storage by the compiler — the explicit
        // `comptime` makes that contract load-bearing (zbc stack-escape
        // rule cannot model the hoisting; the tests exercise the vtables
        // across frames).
        const vtable: ComponentVTable = comptime .{
            .draw = Impl.draw,
            .on_event = if (@hasDecl(T, "onEvent")) Impl.onEvent else null,
            .deinit = if (@hasDecl(T, "deinit")) Impl.deinit else null,
        };
        return .{ .ptr = ptr, .vtable = &vtable };
    }
};

test "make: vtable.draw dispatches with the correct receiver and ctx" {
    const Comp = struct {
        const Self = @This();
        text: []const u8,

        fn draw(self: *Self, ctx: *DrawCtx) anyerror!void {
            _ = try ctx.label(.{ .text = self.text });
        }
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = WidgetTree.init(arena.allocator());
    defer tree.nodes.deinit(arena.allocator());
    var ctx: DrawCtx = .{ .tree = &tree, .arena = arena.allocator() };

    var a: Comp = .{ .text = "alpha" };
    var b: Comp = .{ .text = "beta" };
    const ca = Component.make(Comp, &a);
    const cb = Component.make(Comp, &b);

    try ca.vtable.draw(ca.ptr, &ctx);
    try cb.vtable.draw(cb.ptr, &ctx);

    // Draw side effect landed in the tree via ctx, one node per receiver,
    // each carrying its own receiver's text.
    try std.testing.expectEqual(@as(usize, 2), tree.nodes.items.len);
    try std.testing.expectEqualStrings("alpha", tree.nodes.items[0].kind.label.text);
    try std.testing.expectEqualStrings("beta", tree.nodes.items[1].kind.label.text);
}

test "make: on_event and deinit are null when the type omits them" {
    const Comp = struct {
        const Self = @This();
        fn draw(self: *Self, ctx: *DrawCtx) anyerror!void {
            _ = self;
            _ = ctx;
        }
    };

    var comp: Comp = .{};
    const c = Component.make(Comp, &comp);

    try std.testing.expectEqual(
        @as(?*const fn (*anyopaque, *const Event) void, null),
        c.vtable.on_event,
    );
    try std.testing.expectEqual(
        @as(?*const fn (std.mem.Allocator, *anyopaque) void, null),
        c.vtable.deinit,
    );
}

test "make: on_event dispatches through the vtable when declared" {
    const Comp = struct {
        const Self = @This();
        clicked: bool = false,

        fn draw(self: *Self, ctx: *DrawCtx) anyerror!void {
            _ = self;
            _ = ctx;
        }
        fn onEvent(self: *Self, ev: *const Event) void {
            _ = ev;
            self.clicked = true;
        }
    };

    var comp: Comp = .{};
    const c = Component.make(Comp, &comp);

    try std.testing.expect(c.vtable.on_event != null);
    const ev: Event = .{ .click = .{ .button_id = .root } };
    c.vtable.on_event.?(c.ptr, &ev);
    try std.testing.expect(comp.clicked);
}

test "make: deinit adapter passes the receiver and allocator" {
    // The component's deinit poisons its own memory, so the flags it writes
    // must land in a tracker that survives the poison.
    const Tracker = struct {
        freed: bool = false,
        // SAFETY: assigned via deinit before use; the test asserts it was set.
        received_allocator: std.mem.Allocator = undefined,
    };

    const Comp = struct {
        const Self = @This();
        tracker: *Tracker,

        fn draw(self: *Self, ctx: *DrawCtx) anyerror!void {
            _ = self;
            _ = ctx;
        }
        fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.tracker.freed = true;
            self.tracker.received_allocator = allocator;
            self.* = undefined;
        }
    };

    var tracker: Tracker = .{};
    var comp: Comp = .{ .tracker = &tracker };
    const c = Component.make(Comp, &comp);

    try std.testing.expect(c.vtable.deinit != null);
    c.vtable.deinit.?(std.testing.allocator, c.ptr);
    try std.testing.expect(tracker.freed);
    try std.testing.expectEqual(std.testing.allocator, tracker.received_allocator);
}
