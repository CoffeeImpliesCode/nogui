//! v7 prototype module root — DrawCtx + components (headless-first).
//! See notes/v7-prototype-spec.md.
const std = @import("std");
const noapi = @import("noapi");

pub const Id = @import("id.zig").Id;
pub const ComponentKey = @import("key.zig").ComponentKey;
pub const ComponentId = @import("key.zig").ComponentId;
pub const Rect = @import("widget.zig").Rect;
pub const Size = @import("widget.zig").Size;
pub const ColumnTrack = @import("widget.zig").ColumnTrack;
pub const SharedColumns = @import("widget.zig").SharedColumns;
pub const ScrollAxis = @import("widget.zig").ScrollAxis;
pub const ScrollState = @import("widget.zig").ScrollState;
pub const ScrollSpec = @import("widget.zig").ScrollSpec;
pub const TextOverflow = @import("widget.zig").TextOverflow;
pub const WidgetKind = @import("widget.zig").WidgetKind;
pub const WidgetNode = @import("widget.zig").WidgetNode;
pub const WidgetTree = @import("widget.zig").WidgetTree;
pub const visualBorderOrigin = @import("widget.zig").visualBorderOrigin;
pub const visualBorderRect = @import("widget.zig").visualBorderRect;
pub const visualContentRect = @import("widget.zig").visualContentRect;
pub const pointInClipChain = @import("widget.zig").pointInClipChain;
pub const wrap = @import("callback.zig").wrap;
pub const UserCallback = @import("callback.zig").UserCallback;
pub const bind = @import("callback.zig").bind;
pub const DrawCtx = @import("drawctx.zig").DrawCtx;
pub const ComponentVTable = @import("component.zig").ComponentVTable;
pub const Component = @import("component.zig").Component;
pub const ComponentRegistry = @import("component.zig").ComponentRegistry;
pub const TextureRegistry = @import("runtime.zig").TextureRegistry;
pub const GpuEndpoint = @import("runtime.zig").GpuEndpoint;
pub const GpuFrame = @import("runtime.zig").GpuFrame;
pub const style = @import("style.zig");
pub const Display = style.Display;
pub const Position = style.Position;
pub const FlexDirection = style.FlexDirection;
pub const Direction = style.Direction;
pub const Float = style.Float;
pub const Clear = style.Clear;
pub const FlexWrap = style.FlexWrap;
pub const Justify = style.Justify;
pub const Align = style.Align;
pub const AlignContent = style.AlignContent;
pub const AlignSelf = style.AlignSelf;
pub const BoxSizing = style.BoxSizing;
pub const Sides = style.Sides;
pub const Color = style.Color;
pub const TextureId = style.TextureId;
pub const Layer = style.Layer;
pub const Style = style.Style;
pub const StyleOverride = style.StyleOverride;
pub const PaintStyle = style.PaintStyle;
pub const PaintStyleOverride = style.PaintStyleOverride;
pub const ComponentDefaults = style.ComponentDefaults;
pub const OptionalFloatOverride = style.OptionalFloatOverride;
pub const TextureOverride = style.TextureOverride;
pub const GridTrackBreadth = style.GridTrackBreadth;
pub const GridMinMax = style.GridMinMax;
pub const GridTrack = style.GridTrack;
pub const GridPlacement = style.GridPlacement;
pub const GridLine = style.GridLine;
pub const GridAutoFlow = style.GridAutoFlow;
pub const Dimension = style.Dimension;
pub const LengthPercentage = style.LengthPercentage;
pub const LengthPercentageAuto = style.LengthPercentageAuto;
pub const StyleSize = style.Size;
pub const StyleRect = style.Rect;
pub const DimensionSize = style.DimensionSize;
pub const LengthPercentageSize = style.LengthPercentageSize;
pub const LengthPercentageAutoSize = style.LengthPercentageAutoSize;
pub const Insets = style.Insets;
pub const LengthPercentageRect = style.LengthPercentageRect;
pub const ResolvedSize = style.ResolvedSize;
pub const ResolvedInsets = style.ResolvedInsets;
pub const Overflow = style.Overflow;
pub const OverflowAxes = style.OverflowAxes;
pub const ExplicitOverride = style.ExplicitOverride;
pub const Override = style.Override;
pub const DimensionOverride = style.DimensionOverride;
pub const LengthPercentageAutoOverride = style.LengthPercentageAutoOverride;
pub const DimensionSizeOverride = style.DimensionSizeOverride;
pub const InsetsOverride = style.InsetsOverride;
pub const OverflowAxesOverride = style.OverflowAxesOverride;
pub const ResolvedDimensions = style.ResolvedDimensions;
pub const ResolvedConstraints = style.ResolvedConstraints;
pub const ResolvedStyle = style.ResolvedStyle;
pub const directionIsColumn = style.directionIsColumn;
pub const directionIsReverse = style.directionIsReverse;
pub const dimensionFrom = style.dimensionFrom;
pub const lengthPercentageFrom = style.lengthPercentageFrom;
pub const lengthPercentageAutoFrom = style.lengthPercentageAutoFrom;
pub const Event = @import("event.zig").Event;
pub const dispatchClick = @import("event.zig").dispatchClick;
pub const FrameOutput = @import("headless.zig").FrameOutput;
pub const treeToJson = @import("headless.zig").treeToJson;
pub const TreeJsonOptions = @import("headless.zig").TreeJsonOptions;
pub const treeToJsonWith = @import("headless.zig").treeToJsonWith;
pub const App = @import("app.zig").App;
pub const headless = @import("headless.zig");
pub const hitTest = @import("input.zig").hitTest;
pub const app = @import("app.zig");
pub const callback = @import("callback.zig");
pub const drawcmd = @import("drawcmd.zig");
pub const event = @import("event.zig");
pub const flex = @import("flex.zig");
pub const layout = @import("layout/root.zig");
pub const input = @import("input.zig");
pub const widget = @import("widget.zig");
pub const runtime = @import("runtime.zig");

test {
    _ = @import("taffy_block_conformance.zig");
    _ = @import("taffy_flex_conformance.zig");
    _ = @import("taffy_grid_conformance.zig");
    _ = @import("layout/sizing_test.zig");
    _ = @import("layout/context_test.zig");
    _ = @import("layout/root_test.zig");
    _ = @import("layout/block_float_test.zig");
    _ = @import("layout/block_intrinsic_request_test.zig");
    _ = @import("layout/flex_test.zig");
    _ = @import("layout/flex_intrinsic_test.zig");
    _ = @import("layout/flex_percentage_basis_test.zig");
    _ = @import("layout/grid_test.zig");
    _ = @import("layout/grid_percentage_basis_test.zig");
    _ = @import("layout/dispatch_test.zig");
    _ = @import("layout/dispatch_auto_test.zig");
    _ = @import("layout/dispatch_root_auto_test.zig");
    _ = @import("layout/dispatch_forest_test.zig");
    _ = @import("layout/dispatch_grid_remeasure_test.zig");
    _ = @import("layout/dispatch_flex_remeasure_test.zig");
    _ = @import("layout/dispatch_block_remeasure_test.zig");
}

test "canonical module exports App and DrawCtx" {
    _ = App;
    _ = DrawCtx;
}

test "root component defaults scope only the root draw" {
    const Root = struct {
        const Self = @This();
        pub const default_style: Style = .{ .direction = .row, .gap = 9 };
        pub const default_paint: PaintStyle = .{ .fill = .{ 0.25, 0.5, 0.75, 1 } };
        label_id: Id = .root,

        pub fn draw(self: *Self, ctx: *DrawCtx) anyerror!void {
            self.label_id = try ctx.label(.{ .text = "root" });
        }
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = WidgetTree.init(arena.allocator());
    defer tree.deinit();
    var ctx: DrawCtx = .{ .tree = &tree, .arena = arena.allocator() };
    var root_component: Root = .{};
    const erased = Component.make(Root, &root_component);
    ctx.component_defaults = erased.defaults();
    try erased.vtable.draw(erased.ptr, &ctx);
    ctx.component_defaults = .{};

    const node = tree.node(root_component.label_id).?;
    try std.testing.expectEqual(FlexDirection.row, node.style.direction);
    try std.testing.expectEqual(@as(f32, 9), node.style.gap);
    try std.testing.expectEqual([4]f32{ 0.25, 0.5, 0.75, 1 }, node.paint.fill);
    try std.testing.expectEqual(@as(?Style, null), ctx.component_defaults.style);
    try std.testing.expectEqual(@as(?PaintStyle, null), ctx.component_defaults.paint);
}

const GpuLifecycleEvent = enum { init, frame, deinit };

const GpuLifecycleLog = struct {
    events: [8]GpuLifecycleEvent = .{.init} ** 8,
    count: usize = 0,

    fn append(self: *GpuLifecycleLog, item: GpuLifecycleEvent) void {
        std.debug.assert(self.count < self.events.len);
        self.events[self.count] = item;
        self.count += 1;
    }

    fn slice(self: *const GpuLifecycleLog) []const GpuLifecycleEvent {
        return self.events[0..self.count];
    }
};

const GpuLifecycleChild = struct {
    log: *GpuLifecycleLog,

    pub fn initGpu(self: *GpuLifecycleChild, endpoint: *GpuEndpoint) !void {
        _ = endpoint;
        self.log.append(.init);
    }

    pub fn frameGpu(self: *GpuLifecycleChild, frame: *GpuFrame) !void {
        _ = frame;
        self.log.append(.frame);
    }

    pub fn deinitGpu(self: *GpuLifecycleChild, endpoint: *GpuEndpoint) void {
        _ = endpoint;
        self.log.append(.deinit);
    }

    pub fn draw(self: *GpuLifecycleChild, ctx: *DrawCtx) !void {
        _ = self;
        _ = ctx;
    }
};

const GpuLifecycleRoot = struct {
    child: GpuLifecycleChild,
    show_child: bool = true,

    pub fn draw(self: *GpuLifecycleRoot, ctx: *DrawCtx) !void {
        if (self.show_child) {
            try ctx.component(GpuLifecycleChild, .{ .key = .{ .static = "gpu-child" } }, &self.child);
        }
    }
};

test "GPU lifecycle initializes once, frames after layout, and tears down once" {
    var log: GpuLifecycleLog = .{};
    var root: GpuLifecycleRoot = .{ .child = .{ .log = &log } };
    var app_instance = App.init(std.testing.allocator);
    _ = try app_instance.register(GpuLifecycleRoot, &root);

    var gpu: noapi.Gpu = undefined;
    var endpoint: GpuEndpoint = .{ .gpu = &gpu };
    try app_instance.attachGpu(&endpoint);

    var command_buffer: noapi.CommandBuffer = undefined;
    var gpu_frame: GpuFrame = .{
        .endpoint = &endpoint,
        .command_buffer = &command_buffer,
        .extent = .{ .width = 100, .height = 100 },
        .frame_index = 0,
    };
    _ = try app_instance.frameWithGpu(
        GpuLifecycleRoot,
        &root,
        1,
        .{ .width = 100, .height = 100 },
        &gpu_frame,
    );
    gpu_frame.frame_index = 1;
    _ = try app_instance.frameWithGpu(
        GpuLifecycleRoot,
        &root,
        2,
        .{ .width = 100, .height = 100 },
        &gpu_frame,
    );

    root.show_child = false;
    gpu_frame.frame_index = 0;
    _ = try app_instance.frameWithGpu(
        GpuLifecycleRoot,
        &root,
        3,
        .{ .width = 100, .height = 100 },
        &gpu_frame,
    );
    try std.testing.expectEqualSlices(
        GpuLifecycleEvent,
        &.{ .init, .frame, .frame, .deinit },
        log.slice(),
    );

    app_instance.deinit();
    try std.testing.expectEqual(@as(usize, 4), log.count);
}

test "GPU lifecycle is a headless no-op" {
    var log: GpuLifecycleLog = .{};
    var root: GpuLifecycleRoot = .{ .child = .{ .log = &log } };
    var app_instance = App.init(std.testing.allocator);
    _ = try app_instance.register(GpuLifecycleRoot, &root);

    _ = try app_instance.frame(
        GpuLifecycleRoot,
        &root,
        1,
        .{ .width = 100, .height = 100 },
    );
    root.show_child = false;
    _ = try app_instance.frame(
        GpuLifecycleRoot,
        &root,
        2,
        .{ .width = 100, .height = 100 },
    );
    app_instance.deinit();

    try std.testing.expectEqual(@as(usize, 0), log.count);
}

test "App deinit tears down each mounted GPU component before detach" {
    var log: GpuLifecycleLog = .{};
    var root: GpuLifecycleRoot = .{ .child = .{ .log = &log } };
    var app_instance = App.init(std.testing.allocator);
    _ = try app_instance.register(GpuLifecycleRoot, &root);

    var gpu: noapi.Gpu = undefined;
    var endpoint: GpuEndpoint = .{ .gpu = &gpu };
    try app_instance.attachGpu(&endpoint);
    var command_buffer: noapi.CommandBuffer = undefined;
    var gpu_frame: GpuFrame = .{
        .endpoint = &endpoint,
        .command_buffer = &command_buffer,
        .extent = .{ .width = 100, .height = 100 },
        .frame_index = 0,
    };
    _ = try app_instance.frameWithGpu(
        GpuLifecycleRoot,
        &root,
        1,
        .{ .width = 100, .height = 100 },
        &gpu_frame,
    );

    app_instance.deinit();
    try std.testing.expectEqualSlices(
        GpuLifecycleEvent,
        &.{ .init, .frame, .deinit },
        log.slice(),
    );
}
