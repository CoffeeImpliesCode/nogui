const std = @import("std");
const noapi = @import("noapi");
const nogui = @import("nogui");
const tracy = @import("tracy");

const DrawCtx = nogui.DrawCtx;
const Event = nogui.Event;
const GpuEndpoint = nogui.GpuEndpoint;
const GpuFrame = nogui.GpuFrame;
const Id = nogui.Id;
const Rect = nogui.Rect;
const WidgetTree = nogui.WidgetTree;
const absoluteRect = nogui.widget.absoluteRect;
const srgbToOklab = @import("text.zig").srgbToOklab;

pub const texture_width: u32 = 512;
pub const texture_height: u32 = 384;
pub const max_iterations: u32 = 256;

const shader_bytes = @embedFile("mandelbrot_comp.spv");
const shader_spv: []const u32 = @alignCast(std.mem.bytesAsSlice(u32, shader_bytes));

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
    widget_id: ?Id = null,
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

        const zone = tracy.Zone.begin(.{ .name = "mandelbrot", .src = @src() });
        defer zone.end();
        const params: *MandelParams = @ptrCast(@alignCast(self.params_buf.?.cpu));
        params.* = .{
            .size = .{ texture_width, texture_height },
            .center = self.center,
            .scale = self.scale,
            .time = @as(f32, @floatCast(@as(f64, @floatFromInt(self.time_ms)) / 1000.0)),
            .max_iter = max_iterations,
            .precision = self.precision,
        };

        const command_buffer = frame.command_buffer;
        command_buffer.setComputeShader(self.shader.?);
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

    pub fn onEvent(self: *MandelbrotComponent, event: *const Event) void {
        self.refreshRect();
        switch (event.*) {
            .mouse_move => |move| {
                if (self.drag) |drag| {
                    self.applyPan(.{ move.x, move.y }, drag);
                }
            },
            .mouse_down => |down| {
                if (down.button == .left and self.pointInRect(.{ down.x, down.y })) {
                    self.drag = .{ .mouse = .{ down.x, down.y }, .center = self.center };
                }
            },
            .mouse_up => {
                if (self.drag != null) self.drag = null;
            },
            .mouse_wheel => |wheel| {
                if (wheel.delta_y != 0) {
                    self.scale = @max(
                        self.scale * @exp(@as(f64, wheel.delta_y) * 0.05),
                        10,
                    );
                }
            },
            else => {},
        }
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
            .label = "reset",
            .on_click = MandelbrotComponent.reset,
            .color = c_text,
            .padding = .{ .left = 12, .right = 12, .top = 5, .bottom = 5 },
            .radius = .{ .top = 7, .right = 7, .bottom = 7, .left = 7 },
            .border = .{ .top = 1, .right = 1, .bottom = 1, .left = 1 },
            .border_color = c_border_strong,
            .fill = c_card_deep,
            .gradient = srgbToOklab(c_card_deep),
        });

        _ = try ctx.row(.{});
        defer ctx.pop();
        self.widget_id = try ctx.column(.{
            .texture = self.bindless_index,
            .basis = 480,
            .box_sizing = .border_box,
            .border = .{ .top = 1, .right = 1, .bottom = 1, .left = 1 },
            .border_color = c_border,
            .radius = .{ .top = 8, .right = 8, .bottom = 8, .left = 8 },
        });
        self.tree = ctx.tree;
        defer ctx.pop();
        _ = try ctx.spacer(.{ .size = 190 });
    }

    fn precisionLabel(arena: std.mem.Allocator, precision: u32) ![]const u8 {
        const mode = switch (precision) {
            0 => "f32",
            1 => "f64",
            else => "adaptive",
        };
        return std.fmt.allocPrint(arena, "Mandelbrot  [{s}]", .{mode});
    }

    fn refreshRect(self: *MandelbrotComponent) void {
        const tree = self.tree orelse return;
        const widget_id = self.widget_id orelse return;
        self.rect = absoluteRect(tree, widget_id);
    }

    fn pointInRect(self: *const MandelbrotComponent, point: [2]f32) bool {
        return point[0] >= self.rect.x and point[0] < self.rect.x + self.rect.w and
            point[1] >= self.rect.y and point[1] < self.rect.y + self.rect.h;
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
