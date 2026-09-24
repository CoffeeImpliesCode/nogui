//! Type-erased component dispatch: vtable + opaque receiver.
//!
//! Every element of a UI — including the root — is a `Component(T)`
//! created with `Component.make(T, ptr)`. `draw` is mandatory;
//! `onRoutedEvent`, `onFrame`, `onPrecisionKey`, `deinit`, GPU lifecycle
//! hooks, and typed `default_style`, `default_paint`, and `default_text`
//! declarations are optional.
const std = @import("std");

const DrawCtx = @import("drawctx.zig").DrawCtx;
const DispatchContext = @import("event.zig").DispatchContext;
const WidgetTree = @import("widget.zig").WidgetTree;
const layout = @import("layout/root.zig");
const ComponentId = @import("key.zig").ComponentId;
const GpuEndpoint = @import("runtime.zig").GpuEndpoint;
const GpuFrame = @import("runtime.zig").GpuFrame;
const model_type = @import("model.zig");
const style = @import("style.zig");
const Style = style.Style;
const PaintStyle = style.PaintStyle;
const TextStyleOverride = @import("text.zig").TextStyleOverride;
pub const ComponentDefaults = style.ComponentDefaults;

/// Type-erased operations for a component of any concrete type T.
/// `deinit` takes the allocator first, then the opaque receiver: it frees
/// the component's internals and poisons the receiver; the OWNER of the
/// concrete allocation calls `allocator.destroy` after it returns.
pub const ComponentVTable = struct {
    receiver_type: *const u8,
    draw: *const fn (*anyopaque, *DrawCtx) anyerror!void,
    default_style: ?*const fn () Style,
    default_paint: ?*const fn () PaintStyle,
    default_text: ?*const fn () TextStyleOverride,
    on_routed_event: ?*const fn (*anyopaque, *DispatchContext) void,
    on_frame: ?*const fn (*anyopaque, u64) void,
    on_precision_key: ?*const fn (*anyopaque) void,
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
            .text = if (self.vtable.default_text) |default_text| default_text() else null,
        };
    }

    /// Build a Component from a concrete type. T must declare
    /// `draw(self: *T, ctx: *DrawCtx) !void` (checked at comptime).
    /// Lifecycle hooks and typed layout, paint, and text default
    /// declarations are optional. Adapters cast the opaque receiver back to
    /// `*T` and dispatch with `.auto`.
    pub fn make(comptime T: type, ptr: *T) Component {
        return makeWithModel(T, null, ptr);
    }

    /// Keep the per-App view as the callback receiver; borrow model data only
    /// for the duration of this draw call, never into a frame node.
    pub fn makeModel(comptime M: type, comptime V: type, ptr: *V) Component {
        return makeWithModel(V, M, ptr);
    }

    fn makeWithModel(comptime T: type, comptime ModelType: ?type, ptr: *T) Component {
        if (!@hasDecl(T, "draw")) {
            @compileError("Component type " ++ @typeName(T) ++ " must declare draw");
        }

        const Impl = struct {
            fn draw(p: *anyopaque, ctx: *DrawCtx) anyerror!void {
                const view: *T = @ptrCast(@alignCast(p));
                const saved_defaults = ctx.component_defaults;
                defer ctx.component_defaults = saved_defaults;
                if (std.meta.eql(ctx.component_identity, ComponentId.root)) {
                    ctx.component_defaults = componentDefaults();
                }
                if (ModelType) |M| {
                    const model_context = ctx.context orelse return error.ModelContextUnavailable;
                    const weak = try model_context.root(M);
                    const DrawUser = struct { view: *T, ctx: *DrawCtx };
                    var user: DrawUser = .{ .view = view, .ctx = ctx };
                    try model_context.read(M, weak, &user, struct {
                        fn draw(model: *const M, draw_user: *DrawUser) anyerror!void {
                            try @call(.auto, T.draw, .{
                                draw_user.view,
                                model,
                                draw_user.ctx,
                            });
                        }
                    }.draw);
                } else {
                    try @call(.auto, T.draw, .{ view, ctx });
                }
            }
            fn componentDefaults() ComponentDefaults {
                return .{
                    .style = if (@hasDecl(T, "default_style")) T.default_style else null,
                    .paint = if (@hasDecl(T, "default_paint")) T.default_paint else null,
                    .text = if (@hasDecl(T, "default_text")) T.default_text else null,
                };
            }
            fn defaultStyle() Style {
                return @field(T, "default_style");
            }
            fn defaultPaint() PaintStyle {
                return @field(T, "default_paint");
            }
            fn defaultText() TextStyleOverride {
                return @field(T, "default_text");
            }
            fn onRoutedEvent(p: *anyopaque, context: *DispatchContext) void {
                const t: *T = @ptrCast(@alignCast(p));
                @call(.auto, T.onRoutedEvent, .{ t, context });
            }
            fn onFrame(p: *anyopaque, time_ms: u64) void {
                const t: *T = @ptrCast(@alignCast(p));
                @call(.auto, T.onFrame, .{ t, time_ms });
            }
            fn onPrecisionKey(p: *anyopaque) void {
                const t: *T = @ptrCast(@alignCast(p));
                @call(.auto, T.onPrecisionKey, .{t});
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
            .receiver_type = model_type.marker(T),
            .draw = Impl.draw,
            .default_style = if (@hasDecl(T, "default_style")) Impl.defaultStyle else null,
            .default_paint = if (@hasDecl(T, "default_paint")) Impl.defaultPaint else null,
            .default_text = if (@hasDecl(T, "default_text")) Impl.defaultText else null,
            .on_routed_event = if (@hasDecl(T, "onRoutedEvent")) Impl.onRoutedEvent else null,
            .on_frame = if (@hasDecl(T, "onFrame")) Impl.onFrame else null,
            .on_precision_key = if (@hasDecl(T, "onPrecisionKey")) Impl.onPrecisionKey else null,
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
    defer tree.deinit();
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

test "make: on_routed_event and deinit are null when the type omits them" {
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
        @as(?*const fn (*anyopaque, *DispatchContext) void, null),
        c.vtable.on_routed_event,
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
        pub const default_style: Style = .{ .direction = .row, .gap = .{ .length = 11 } };
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
    const deinit = c.vtable.deinit orelse return error.TestUnexpectedResult;
    deinit(std.testing.allocator, c.ptr);
    try std.testing.expect(tracker.freed);
    try std.testing.expectEqual(std.testing.allocator, tracker.received_allocator);
}

// A component declares its typed defaults as ordinary public constants, one
// per scope. The text scope is no different: a `default_text` declaration must
// reach every label the component builds, an explicit `text_style` on the
// widget outranks it field by field, and a label drawn outside the component
// must not inherit it.
test "make: a declared default_text reaches the labels a root component builds" {
    const FrameNodeId = @import("id.zig").FrameNodeId;

    const declared_foreground: [4]f32 = .{ 0.9, 0.2, 0.4, 1 };
    const declared_size: f32 = 21;
    const own_foreground: [4]f32 = .{ 0.1, 0.3, 0.7, 1 };

    const Panel = struct {
        const Self = @This();
        pub const default_style: Style = .{ .direction = .row, .gap = .{ .length = 6 } };
        pub const default_paint: PaintStyle = .{ .fill = .{ 0.2, 0.6, 0.2, 1 } };
        pub const default_text: TextStyleOverride = .{
            .foreground = declared_foreground,
            .font_fields = .{ .size = declared_size },
        };

        container: FrameNodeId = .root,
        inherited: FrameNodeId = .root,
        own: FrameNodeId = .root,
        tinted: FrameNodeId = .root,

        pub fn draw(self: *Self, ctx: *DrawCtx) anyerror!void {
            self.container = try ctx.column(.{});
            self.inherited = try ctx.label(.{ .text = "inherited" });
            self.own = try ctx.label(.{
                .text = "own",
                .text_style = .{
                    .foreground = own_foreground,
                    .font_fields = .{ .size = 9 },
                },
            });
            self.tinted = try ctx.label(.{ .text = "tinted", .color = own_foreground });
            ctx.pop();
        }
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = WidgetTree.init(arena.allocator());
    defer tree.deinit();
    var ctx: DrawCtx = .{
        .tree = &tree,
        .arena = arena.allocator(),
        .component_identity = .root,
    };

    // A label drawn before the component: the reference for what a scope-less
    // label resolves to in this frame.
    const control = try ctx.label(.{ .text = "control" });

    var panel: Panel = .{};
    const erased = Component.make(Panel, &panel);
    try erased.vtable.draw(erased.ptr, &ctx);

    // Drawn after the component returned, so the root scope is in place again.
    const after = try ctx.label(.{ .text = "after" });

    // The scope is restored on return, the text half included.
    try std.testing.expectEqual(
        @as(?TextStyleOverride, null),
        ctx.component_defaults.text,
    );
    try std.testing.expectEqual(@as(?Style, null), ctx.component_defaults.style);
    try std.testing.expectEqual(@as(?PaintStyle, null), ctx.component_defaults.paint);

    try layout.layoutTree(&tree, .{
        .allocator = arena.allocator(),
        .available = .{ .width = 200, .height = 100 },
    });

    // The layout and paint scopes are untouched by the text one: they still
    // resolve onto the container the component built.
    const container = tree.node(panel.container) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(style.FlexDirection.row, container.style.direction);
    try std.testing.expect(std.meta.eql(
        @as(style.LengthPercentage, .{ .length = 6 }),
        container.style.gap,
    ));
    try std.testing.expectEqual([4]f32{ 0.2, 0.6, 0.2, 1 }, container.paint.fill);

    const inherited = tree.node(panel.inherited).?.text_request orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqualSlices(f32, &declared_foreground, &inherited.style.foreground);
    try std.testing.expectEqual(declared_size, inherited.fontSize());

    // An explicit `text_style` is authorship and outranks the declared default
    // in every field it names.
    const own = tree.node(panel.own).?.text_request orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqualSlices(f32, &own_foreground, &own.style.foreground);
    try std.testing.expectEqual(@as(f32, 9), own.fontSize());

    // A `.color` option authors the foreground alone, so the declared size
    // still fills the field nothing above authored.
    const tinted = tree.node(panel.tinted).?.text_request orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqualSlices(f32, &own_foreground, &tinted.style.foreground);
    try std.testing.expectEqual(declared_size, tinted.fontSize());

    // The default is the component's own: a sibling outside it resolves
    // exactly like the control label, never like the labels above.
    const control_request = tree.node(control).?.text_request orelse
        return error.TestUnexpectedResult;
    const after_request = tree.node(after).?.text_request orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(control_request.fontSize(), after_request.fontSize());
    try std.testing.expectEqualSlices(
        f32,
        &control_request.style.foreground,
        &after_request.style.foreground,
    );
    try std.testing.expect(after_request.fontSize() != declared_size);
    try std.testing.expect(!std.meta.eql(after_request.style.foreground, declared_foreground));
}

// A nested component installs its own declared defaults for its own subtree,
// and the enclosing component's scope is intact again once it returns.
test "make: a nested component's declared default_text scopes to its own subtree" {
    const FrameNodeId = @import("id.zig").FrameNodeId;

    const parent_foreground: [4]f32 = .{ 0.8, 0.1, 0.1, 1 };
    const child_foreground: [4]f32 = .{ 0.1, 0.1, 0.8, 1 };
    const own_foreground: [4]f32 = .{ 0.5, 0.5, 0.5, 1 };
    const parent_size: f32 = 24;
    const child_size: f32 = 8;

    const Child = struct {
        const Self = @This();
        pub const default_text: TextStyleOverride = .{
            .foreground = child_foreground,
            .font_fields = .{ .size = child_size },
        };

        inner: FrameNodeId = .root,
        inner_own: FrameNodeId = .root,

        pub fn draw(self: *Self, ctx: *DrawCtx) anyerror!void {
            self.inner = try ctx.label(.{ .text = "inner" });
            self.inner_own = try ctx.label(.{
                .text = "inner own",
                .text_style = .{
                    .foreground = own_foreground,
                    .font_fields = .{ .size = 30 },
                },
            });
        }
    };

    const Parent = struct {
        const Self = @This();
        pub const default_text: TextStyleOverride = .{
            .foreground = parent_foreground,
            .font_fields = .{ .size = parent_size },
        };

        child: Child = .{},
        before: FrameNodeId = .root,
        after: FrameNodeId = .root,

        pub fn draw(self: *Self, ctx: *DrawCtx) anyerror!void {
            _ = try ctx.column(.{});
            self.before = try ctx.label(.{ .text = "before" });
            try ctx.component(Child, .{ .key = .{ .static = "child" } }, &self.child);
            self.after = try ctx.label(.{ .text = "after" });
            ctx.pop();
        }
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = WidgetTree.init(arena.allocator());
    defer tree.deinit();
    var ctx: DrawCtx = .{
        .tree = &tree,
        .arena = arena.allocator(),
        .component_identity = .root,
    };

    var parent: Parent = .{};
    const erased = Component.make(Parent, &parent);
    try erased.vtable.draw(erased.ptr, &ctx);
    try std.testing.expectEqual(
        @as(?TextStyleOverride, null),
        ctx.component_defaults.text,
    );

    try layout.layoutTree(&tree, .{
        .allocator = arena.allocator(),
        .available = .{ .width = 200, .height = 100 },
    });

    // The nested component gave the enclosing scope back, so the labels on
    // either side of it both carry the parent's declaration.
    const before = tree.node(parent.before).?.text_request orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqualSlices(f32, &parent_foreground, &before.style.foreground);
    try std.testing.expectEqual(parent_size, before.fontSize());

    const after = tree.node(parent.after).?.text_request orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqualSlices(f32, &parent_foreground, &after.style.foreground);
    try std.testing.expectEqual(parent_size, after.fontSize());

    // Inside the nested component its own declaration is the one in force, and
    // the widget's `text_style` still outranks it.
    const inner = tree.node(parent.child.inner).?.text_request orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqualSlices(f32, &child_foreground, &inner.style.foreground);
    try std.testing.expectEqual(child_size, inner.fontSize());

    const inner_own = tree.node(parent.child.inner_own).?.text_request orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqualSlices(f32, &own_foreground, &inner_own.style.foreground);
    try std.testing.expectEqual(@as(f32, 30), inner_own.fontSize());
}
