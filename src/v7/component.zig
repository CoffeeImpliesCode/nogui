//! Type-erased component dispatch: vtable + opaque receiver.
//! Per the prototype spec (notes/v7-prototype-spec.md §5).
//!
//! Every element of a UI — including the root — is a `Component(T)`
//! created with `Component.make(T, ptr)`. `draw` is mandatory; `onEvent`,
//! `deinit`, GPU lifecycle hooks, and typed `default_style` /
//! `default_paint` declarations are optional and detected at comptime.
const std = @import("std");

const DrawCtx = @import("drawctx.zig").DrawCtx;
const Event = @import("event.zig").Event;
const WidgetTree = @import("widget.zig").WidgetTree;
const ComponentId = @import("key.zig").ComponentId;
const GpuEndpoint = @import("runtime.zig").GpuEndpoint;
const GpuFrame = @import("runtime.zig").GpuFrame;
const style = @import("style.zig");
const Style = style.Style;
const PaintStyle = style.PaintStyle;
pub const ComponentDefaults = style.ComponentDefaults;

/// Type-erased operations for a component of any concrete type T.
/// `deinit` takes the allocator first, then the opaque receiver: it frees
/// the component's internals and poisons the receiver; the OWNER of the
/// concrete allocation calls `allocator.destroy` after it returns.
pub const ComponentVTable = struct {
    draw: *const fn (*anyopaque, *DrawCtx) anyerror!void,
    default_style: ?*const fn () Style,
    default_paint: ?*const fn () PaintStyle,
    on_event: ?*const fn (*anyopaque, *const Event) void,
    deinit: ?*const fn (std.mem.Allocator, *anyopaque) void,
    init_gpu: ?*const fn (*anyopaque, *GpuEndpoint) anyerror!void,
    frame_gpu: ?*const fn (*anyopaque, *GpuFrame) anyerror!void,
    deinit_gpu: ?*const fn (*anyopaque, *GpuEndpoint) void,
};

/// A type-erased component: an opaque pointer plus its vtable.
pub const Component = struct {
    ptr: *anyopaque,
    vtable: *const ComponentVTable,
    /// Return the concrete component's typed defaults. Types without a
    /// declaration contribute an empty value for that half of the scope.
    pub fn defaults(self: Component) ComponentDefaults {
        return .{
            .style = if (self.vtable.default_style) |default_style| default_style() else null,
            .paint = if (self.vtable.default_paint) |default_paint| default_paint() else null,
        };
    }

    /// Build a Component from a concrete type. T must declare
    /// `draw(self: *T, ctx: *DrawCtx) !void` (checked at comptime).
    /// Lifecycle hooks and typed `default_style` / `default_paint`
    /// declarations are optional. Adapters cast the opaque receiver back to
    /// `*T` and dispatch with `.auto`.
    pub fn make(comptime T: type, ptr: *T) Component {
        if (!@hasDecl(T, "draw")) {
            @compileError("Component type " ++ @typeName(T) ++ " must declare draw(self: *T, ctx: *DrawCtx) !void");
        }

        const Impl = struct {
            fn draw(p: *anyopaque, ctx: *DrawCtx) anyerror!void {
                const t: *T = @ptrCast(@alignCast(p));
                if (std.meta.eql(ctx.component_identity, ComponentId.root)) {
                    const saved_defaults = ctx.component_defaults;
                    defer ctx.component_defaults = saved_defaults;
                    ctx.component_defaults = componentDefaults();
                }
                return @call(.auto, T.draw, .{ t, ctx });
            }
            fn componentDefaults() ComponentDefaults {
                return .{
                    .style = if (@hasDecl(T, "default_style")) T.default_style else null,
                    .paint = if (@hasDecl(T, "default_paint")) T.default_paint else null,
                };
            }
            fn defaultStyle() Style {
                return @field(T, "default_style");
            }
            fn defaultPaint() PaintStyle {
                return @field(T, "default_paint");
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
            fn initGpu(p: *anyopaque, endpoint: *GpuEndpoint) anyerror!void {
                const t: *T = @ptrCast(@alignCast(p));
                return @call(.auto, T.initGpu, .{ t, endpoint });
            }
            fn frameGpu(p: *anyopaque, frame: *GpuFrame) anyerror!void {
                const t: *T = @ptrCast(@alignCast(p));
                return @call(.auto, T.frameGpu, .{ t, frame });
            }
            fn deinitGpu(p: *anyopaque, endpoint: *GpuEndpoint) void {
                const t: *T = @ptrCast(@alignCast(p));
                @call(.auto, T.deinitGpu, .{ t, endpoint });
            }
        };

        // All fields are comptime-known (fn pointers + @hasDecl), so the
        // const is hoisted to static storage by the compiler — the explicit
        // `comptime` makes that contract load-bearing (zbc stack-escape
        // rule cannot model the hoisting; the tests exercise the vtables
        // across frames).
        const vtable: ComponentVTable = comptime .{
            .draw = Impl.draw,
            .default_style = if (@hasDecl(T, "default_style")) Impl.defaultStyle else null,
            .default_paint = if (@hasDecl(T, "default_paint")) Impl.defaultPaint else null,
            .on_event = if (@hasDecl(T, "onEvent")) Impl.onEvent else null,
            .deinit = if (@hasDecl(T, "deinit")) Impl.deinit else null,
            .init_gpu = if (@hasDecl(T, "initGpu")) Impl.initGpu else null,
            .frame_gpu = if (@hasDecl(T, "frameGpu")) Impl.frameGpu else null,
            .deinit_gpu = if (@hasDecl(T, "deinitGpu")) Impl.deinitGpu else null,
        };

        return .{ .ptr = ptr, .vtable = &vtable };
    }
};

/// Persistent metadata for one stable component identity.
pub const ComponentEntry = struct {
    component: Component,
    last_seen_frame: u64,
    gpu_initialized: bool = false,
};

/// App-owned stable component identity registry.
pub const ComponentRegistry = struct {
    map: std.AutoHashMapUnmanaged(ComponentId, ComponentEntry) = .empty,
    gpa: std.mem.Allocator,

    pub fn init(gpa: std.mem.Allocator) ComponentRegistry {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *ComponentRegistry) void {
        self.map.deinit(self.gpa);
        self.* = undefined;
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
    try std.testing.expectEqual(
        @as(?*const fn (*anyopaque, *GpuEndpoint) anyerror!void, null),
        c.vtable.init_gpu,
    );
    try std.testing.expectEqual(
        @as(?*const fn (*anyopaque, *GpuFrame) anyerror!void, null),
        c.vtable.frame_gpu,
    );
    try std.testing.expectEqual(
        @as(?*const fn (*anyopaque, *GpuEndpoint) void, null),
        c.vtable.deinit_gpu,
    );
}

test "make: typed default adapters are present only for declared values" {
    const WithDefaults = struct {
        const Self = @This();
        pub const default_style: Style = .{ .direction = .row, .gap = 11 };
        pub const default_paint: PaintStyle = .{ .layer = 4 };

        fn draw(self: *Self, ctx: *DrawCtx) anyerror!void {
            _ = self;
            _ = ctx;
        }
    };
    const WithoutDefaults = struct {
        const Self = @This();

        fn draw(self: *Self, ctx: *DrawCtx) anyerror!void {
            _ = self;
            _ = ctx;
        }
    };

    var with_defaults: WithDefaults = .{};
    const with_component = Component.make(WithDefaults, &with_defaults);
    try std.testing.expect(with_component.vtable.default_style != null);
    try std.testing.expect(with_component.vtable.default_paint != null);
    try std.testing.expectEqual(
        @as(?Style, WithDefaults.default_style),
        with_component.defaults().style,
    );
    try std.testing.expectEqual(
        @as(?PaintStyle, WithDefaults.default_paint),
        with_component.defaults().paint,
    );

    var without_defaults: WithoutDefaults = .{};
    const without_component = Component.make(WithoutDefaults, &without_defaults);
    try std.testing.expect(without_component.vtable.default_style == null);
    try std.testing.expect(without_component.vtable.default_paint == null);
    try std.testing.expectEqual(@as(?Style, null), without_component.defaults().style);
    try std.testing.expectEqual(@as(?PaintStyle, null), without_component.defaults().paint);
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
