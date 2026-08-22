//! v7 prototype module root — DrawCtx + components (headless-first).
//! See notes/v7-prototype-spec.md.
const std = @import("std");
const noapi = @import("noapi");

pub const Id = @import("id.zig").Id;
pub const ComponentKey = @import("key.zig").ComponentKey;
pub const ComponentId = @import("key.zig").ComponentId;
pub const Rect = @import("widget.zig").Rect;
pub const Size = @import("widget.zig").Size;
pub const FlexChild = @import("widget.zig").FlexChild;
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
pub const Justify = @import("style.zig").Justify;
pub const Align = @import("style.zig").Align;
pub const FlexStyle = @import("flex.zig").FlexStyle;
pub const Style = @import("style.zig").Style;
pub const StyleOverride = @import("style.zig").StyleOverride;
pub const PaintStyle = @import("style.zig").PaintStyle;
pub const PaintStyleOverride = @import("style.zig").PaintStyleOverride;
pub const Display = @import("style.zig").Display;
pub const FlexDirection = @import("style.zig").FlexDirection;
pub const BoxSizing = @import("style.zig").BoxSizing;
pub const Sides = @import("style.zig").Sides;
pub const Color = @import("style.zig").Color;
pub const TextureId = @import("style.zig").TextureId;
pub const Layer = @import("style.zig").Layer;
pub const OptionalFloatOverride = @import("style.zig").OptionalFloatOverride;
pub const TextureOverride = @import("style.zig").TextureOverride;
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
pub const input = @import("input.zig");
pub const widget = @import("widget.zig");
pub const runtime = @import("runtime.zig");

test {
    std.testing.refAllDecls(@This());
}

test "canonical module exports App and DrawCtx" {
    _ = App;
    _ = DrawCtx;
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
