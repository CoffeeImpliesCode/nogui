const std = @import("std");
const noapi = @import("noapi");
const nogui = @import("nogui");
const tracy = @import("tracy");

const DrawCtx = nogui.DrawCtx;
const DispatchContext = nogui.event.DispatchContext;
const GpuEndpoint = nogui.GpuEndpoint;
const GpuFrame = nogui.GpuFrame;
const FrameNodeId = nogui.FrameNodeId;
const Rect = nogui.Rect;
const WidgetTree = nogui.WidgetTree;
const visualBorderRect = nogui.widget.visualBorderRect;
const pointInClipChain = nogui.widget.pointInClipChain;

pub const texture_width: u32 = 512;
pub const texture_height: u32 = 384;
pub const max_iterations: u32 = 256;

const shader_bytes align(@alignOf(u32)) = @embedFile("mandelbrot_comp.spv").*;
const shader_spv: []const u32 = std.mem.bytesAsSlice(u32, &shader_bytes);

const MandelParams = extern struct {
    size: [2]u32,
    center: [2]f64,
    scale: f64,
    time: f32,
    max_iter: u32,
    precision: u32,
};

const MandelDrag = struct {
    mouse: [2]f32,
    center: [2]f64,
};

const c_border: [4]f32 = .{ 0.24, 0.25, 0.33, 0.55 };
const c_border_strong: [4]f32 = .{ 0.34, 0.35, 0.46, 0.75 };
const c_text: [4]f32 = .{ 0.87, 0.87, 0.92, 1 };
const c_text_muted: [4]f32 = .{ 0.46, 0.47, 0.56, 1 };
const c_card_deep: [4]f32 = .{ 0.16, 0.17, 0.22, 1 };

pub const MandelbrotComponent = struct {
    texture: noapi.TextureHandle = .{},
    shader: ?noapi.Shader = null,
    params_buf: ?noapi.GpuPtr = null,
    params_bda: u64 = 0,
    bindless_index: ?u32 = null,
    descriptor_heap: ?noapi.DescriptorHeap = null,
    gpu_ready: bool = false,
    gpu_init_count: u32 = 0,
    gpu_deinit_count: u32 = 0,
    last_unregistered_index: ?u32 = null,

    center: [2]f64 = .{ -0.5, 0 },
    scale: f64 = 300,
    precision: u32 = 2,
    time_ms: u64 = 0,

    drag: ?MandelDrag = null,
    rect: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    /// The keyed viewport box and the one node inside it. Both are dense
    /// frame ids of the tree this component last drew, and together they
    /// name every node a pointer event can land on inside the viewport.
    /// Everything else this component draws — the caption, the reset button
    /// and its label — is not a pointer surface.
    viewport: FrameNodeId = .root,
    viewport_content: FrameNodeId = .root,
    /// The tree that published those ids, restated by every draw.
    tree: ?*const WidgetTree = null,

    pub fn setDescriptorHeap(self: *MandelbrotComponent, heap: noapi.DescriptorHeap) void {
        self.descriptor_heap = heap;
    }

    pub fn onFrame(self: *MandelbrotComponent, time_ms: u64) void {
        self.time_ms = time_ms;
    }

    pub fn reset(self: *MandelbrotComponent) void {
        self.center = .{ -0.5, 0 };
        self.scale = 300;
    }

    pub fn cyclePrecision(self: *MandelbrotComponent) void {
        self.precision = (self.precision + 1) % 3;
    }
    pub fn bindlessSlot(self: *const MandelbrotComponent) ?u32 {
        return self.bindless_index;
    }

    pub fn gpuInitCount(self: *const MandelbrotComponent) u32 {
        return self.gpu_init_count;
    }

    pub fn gpuDeinitCount(self: *const MandelbrotComponent) u32 {
        return self.gpu_deinit_count;
    }

    pub fn lastUnregisteredSlot(self: *const MandelbrotComponent) ?u32 {
        return self.last_unregistered_index;
    }

    pub fn isGpuReady(self: *const MandelbrotComponent) bool {
        return self.gpu_ready;
    }

    pub fn initGpu(self: *MandelbrotComponent, endpoint: *GpuEndpoint) !void {
        const gpu = endpoint.gpu;
        const texture = try gpu.textureCreate(.{
            .dimensions = .{ texture_width, texture_height, 1 },
            .format = .rgba32_float,
            .usage = .{ .sampled = true, .storage = true },
        });
        errdefer gpu.textureDestroy(texture);

        const shader = try gpu.shaderCreate(shader_spv, .compute, "main", "mandelbrot_comp");
        errdefer gpu.shaderDestroy(shader);

        const params_buf = try gpu.gpuMalloc(@sizeOf(MandelParams), 64, .default);
        errdefer gpu.gpuFree(params_buf);

        const bindless_index = try endpoint.registerTexture(texture);
        self.texture = texture;
        self.shader = shader;
        self.params_buf = params_buf;
        self.params_bda = params_buf.gpu;
        self.bindless_index = bindless_index;
        self.gpu_ready = true;
        self.gpu_init_count += 1;
    }

    pub fn frameGpu(self: *MandelbrotComponent, frame: *GpuFrame) !void {
        self.refreshRect();
        const heap = self.descriptor_heap orelse return error.DescriptorHeapUnavailable;
        if (!self.gpu_ready) return error.MandelbrotGpuUnavailable;
        const shader = self.shader orelse return error.MandelbrotGpuUnavailable;
        const params_buf = self.params_buf orelse return error.MandelbrotGpuUnavailable;

        const zone = tracy.Zone.begin(.{ .name = "mandelbrot", .src = @src() });
        defer zone.end();
        const params: *MandelParams = @ptrCast(@alignCast(params_buf.cpu));
        params.* = .{
            .size = .{ texture_width, texture_height },
            .center = self.center,
            .scale = self.scale,
            .time = @as(f32, @floatCast(@as(f64, @floatFromInt(self.time_ms)) / 1000.0)),
            .max_iter = max_iterations,
            .precision = self.precision,
        };

        const command_buffer = frame.command_buffer;
        command_buffer.setComputeShader(shader);
        command_buffer.bindDescriptorSets(heap);
        command_buffer.dispatch(self.params_bda, texture_width / 8, texture_height / 8, 1);
        command_buffer.barrier(.{ .compute = true }, .{ .fragment = true }, .{});
    }

    pub fn deinitGpu(self: *MandelbrotComponent, endpoint: *GpuEndpoint) void {
        self.releaseBindlessTexture(endpoint);
        const gpu = endpoint.gpu;
        if (self.params_buf) |params_buf| gpu.gpuFree(params_buf);
        if (self.shader) |shader| gpu.shaderDestroy(shader);
        if (self.texture.texture.id != 0) gpu.textureDestroy(self.texture);
        self.texture = .{};
        self.params_buf = null;
        self.shader = null;
        self.params_bda = 0;
        self.gpu_ready = false;
        self.gpu_deinit_count += 1;
    }

    fn releaseBindlessTexture(self: *MandelbrotComponent, endpoint: *GpuEndpoint) void {
        const index = self.bindless_index orelse return;
        self.bindless_index = null;
        endpoint.unregisterTexture(index);
        self.last_unregistered_index = index;
    }

    /// The routed path is this component's only input seam. App delivers the
    /// phase and the node being visited, so the viewport answers for itself
    /// and nothing else it draws can pan or zoom it. A press, move, release,
    /// cancel or capture revocation all arrive at the viewport because the
    /// focus manager captured its stable identity, which is why a move or a
    /// release outside the box still belongs here.
    pub fn onRoutedEvent(self: *MandelbrotComponent, context: *DispatchContext) void {
        if (context.phase != .target) return;
        if (context.current_target != context.target) return;
        if (!self.isViewportNode(context.current_target)) return;
        switch (context.event.*) {
            .mouse_move => |move| {
                if (self.drag) |drag| self.applyPan(.{ move.x, move.y }, drag);
            },
            .mouse_down => |down| {
                if (down.button == .left and self.pointInViewport(.{ down.x, down.y })) {
                    self.drag = .{ .mouse = .{ down.x, down.y }, .center = self.center };
                }
            },
            // A lost capture, a cancelled press and a window that stopped
            // taking input all end the pan; none of them delivers a release
            // the component could otherwise wait for forever.
            .mouse_up, .mouse_cancel, .capture_lost, .window_focus_lost => {
                self.drag = null;
            },
            .mouse_wheel => |wheel| {
                if (wheel.delta_y != 0 and self.pointInViewport(.{ wheel.x, wheel.y })) {
                    self.scale = @max(
                        self.scale * @exp(@as(f64, wheel.delta_y) * 0.05),
                        10,
                    );
                }
            },
            else => {},
        }
    }

    fn isViewportNode(self: *const MandelbrotComponent, node: FrameNodeId) bool {
        return node == self.viewport or node == self.viewport_content;
    }

    pub fn draw(self: *MandelbrotComponent, ctx: *DrawCtx) !void {
        _ = try ctx.row(.{ .gap = 8, .@"align" = .center });
        defer ctx.pop();
        _ = try ctx.label(.{
            .text = try precisionLabel(ctx.arena, self.precision),
            .color = c_text_muted,
            .font_size = 11,
            .padding = .{ .left = 6, .right = 6 },
        });
        _ = try ctx.button(.{
            .key = .{ .static = "mandelbrot-reset" },
            .label = "reset",
            .on_click = MandelbrotComponent.reset,
            .color = c_text,
            .padding = .{ .left = 12, .right = 12, .top = 5, .bottom = 5 },
            .radius = .{ .top = 7, .right = 7, .bottom = 7, .left = 7 },
            .border = .{ .top = 1, .right = 1, .bottom = 1, .left = 1 },
            .border_color = c_border_strong,
            .fill = c_card_deep,
        });

        _ = try ctx.row(.{});
        defer ctx.pop();
        self.viewport = try ctx.column(.{
            .key = .{ .static = "viewport" },
            .texture = self.bindless_index,
            .flex_basis = 480,
            .box_sizing = .border_box,
            .border = .{ .top = 1, .right = 1, .bottom = 1, .left = 1 },
            .border_color = c_border,
            .radius = .{ .top = 8, .right = 8, .bottom = 8, .left = 8 },
        });
        self.tree = ctx.tree;
        defer ctx.pop();
        self.viewport_content = try ctx.spacer(.{ .size = 190 });
    }

    fn precisionLabel(arena: std.mem.Allocator, precision: u32) ![]const u8 {
        const mode = switch (precision) {
            0 => "f32",
            1 => "f64",
            else => "adaptive",
        };
        return std.fmt.allocPrint(arena, "Mandelbrot  [{s}]", .{mode});
    }

    /// The showcase hid this component, so the next committed tree has no
    /// viewport to capture, name or pan.
    pub fn clearInputTarget(self: *MandelbrotComponent) void {
        self.drag = null;
        self.viewport = .root;
        self.viewport_content = .root;
        self.tree = null;
        self.rect = .{};
    }

    fn refreshRect(self: *MandelbrotComponent) void {
        const tree = self.tree orelse return;
        self.rect = visualBorderRect(tree, self.viewport);
    }

    fn pointInRect(self: *const MandelbrotComponent, point: [2]f32) bool {
        return point[0] >= self.rect.x and point[0] < self.rect.x + self.rect.w and
            point[1] >= self.rect.y and point[1] < self.rect.y + self.rect.h;
    }

    fn pointInViewport(self: *MandelbrotComponent, point: [2]f32) bool {
        const tree = self.tree orelse return false;
        self.rect = visualBorderRect(tree, self.viewport);
        return self.pointInRect(point) and pointInClipChain(tree, self.viewport, point);
    }

    fn applyPan(self: *MandelbrotComponent, point: [2]f32, drag: MandelDrag) void {
        const scale_x = self.scale * @as(f64, self.rect.w / @as(f32, texture_width));
        const scale_y = self.scale * @as(f64, self.rect.h / @as(f32, texture_height));
        self.center[0] = drag.center[0] - @as(f64, point[0] - drag.mouse[0]) / scale_x;
        self.center[1] = drag.center[1] - @as(f64, point[1] - drag.mouse[1]) / scale_y;
    }
};

const DeinitProbe = struct {
    component: *MandelbrotComponent,
    observed_index: ?u32 = null,
    observed_cleared: bool = false,
};

fn fakeRegisterTexture(_: *anyopaque, _: noapi.TextureHandle) anyerror!u32 {
    return 0;
}

fn recordUnregisterTexture(ptr: *anyopaque, index: u32) void {
    const probe: *DeinitProbe = @ptrCast(@alignCast(ptr));
    probe.observed_index = index;
    probe.observed_cleared = probe.component.bindless_index == null;
}

test "MandelbrotComponent: deinitGpu unregisters before texture teardown" {
    var component: MandelbrotComponent = .{ .bindless_index = 23 };
    var probe: DeinitProbe = .{ .component = &component };
    var registry: nogui.TextureRegistry = .{
        .ptr = &probe,
        .register = fakeRegisterTexture,
        .unregister = recordUnregisterTexture,
    };
    var endpoint: GpuEndpoint = .{ .gpu = undefined, .textures = &registry };

    component.deinitGpu(&endpoint);

    try std.testing.expectEqual(@as(?u32, null), component.bindless_index);
    try std.testing.expectEqual(@as(?u32, 23), probe.observed_index);
    try std.testing.expect(probe.observed_cleared);
}

test "MandelbrotComponent: frameGpu reports missing shader state" {
    var component: MandelbrotComponent = .{
        .gpu_ready = true,
        .descriptor_heap = .{},
    };
    var gpu: noapi.Gpu = undefined;
    var endpoint: GpuEndpoint = .{ .gpu = &gpu };
    var command_buffer: noapi.CommandBuffer = undefined;
    var frame: GpuFrame = .{
        .endpoint = &endpoint,
        .command_buffer = &command_buffer,
        .extent = .{ .width = texture_width, .height = texture_height },
        .frame_index = 0,
    };

    try std.testing.expectError(
        error.MandelbrotGpuUnavailable,
        component.frameGpu(&frame),
    );
}
