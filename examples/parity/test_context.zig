//! Real-font layout and windowless GPU context consumer. No SDL initialization.
const std = @import("std");
const nogui = @import("nogui");
const Cpu = @import("nogui_text");
const Frame = @import("v7_frame");
const Render = @import("v7_render");
const Support = @import("nogui_test");
const font = @import("font_bytes");
const GpuContext = Support.OffscreenContext(Frame, Render);

const View = struct {
    lightness: f32 = 0.35,

    pub fn draw(self: *View, ctx: *nogui.DrawCtx) !void {
        _ = try ctx.row(.{
            .width = 256,
            .height = 96,
            .fill = nogui.paint.Color{ .oklab = .{ .l = self.lightness, .a = 0, .b = 0, .alpha = 1 } },
        });
        defer ctx.pop();
        _ = try ctx.label(.{ .text = "iii", .key = @as(nogui.ComponentKey, .{ .static = "narrow" }) });
        _ = try ctx.label(.{ .text = "WWW", .key = @as(nogui.ComponentKey, .{ .static = "wide" }) });
    }
};

const Shader = struct {
    bytes: []u8,
    words: []const u32,

    fn load(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !Shader {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
        errdefer gpa.free(bytes);
        if (bytes.len == 0 or bytes.len % @sizeOf(u32) != 0) return error.InvalidShaderBytes;
        return .{ .bytes = bytes, .words = @alignCast(std.mem.bytesAsSlice(u32, bytes)) };
    }
};

fn checkPixel(pixels: []const f32, lightness: f32) !void {
    const offset = (60 * 256 + 200) * 4;
    const expected = [4]f32{ lightness, 0, 0, 1 };
    for (pixels[offset..][0..4], expected) |actual, wanted| {
        if (!std.math.isFinite(actual) or @abs(actual - wanted) > 0.001) return error.RenderedColorMismatch;
    }
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args.deinit();
    _ = args.next() orelse return error.MissingExecutableName;
    const vert = try Shader.load(gpa, init.io, args.next() orelse return error.MissingVertexShader);
    defer gpa.free(vert.bytes);
    const frag = try Shader.load(gpa, init.io, args.next() orelse return error.MissingFragmentShader);
    defer gpa.free(frag.bytes);
    const sort = try Shader.load(gpa, init.io, args.next() orelse return error.MissingSortShader);
    defer gpa.free(sort.bytes);
    if (args.next() != null) return error.UnexpectedArgument;

    const cpu = try Support.TextContext(Cpu).create(gpa, .{
        .fonts = &.{.{ .family = "Inter", .bytes = font.bytes }},
        .default_size = Frame.font_size_px,
    });
    defer cpu.deinit() catch @panic("CPU context retained ownership");
    var cpu_view: View = .{};
    try cpu.base.app.mountRoot(View, &cpu_view);
    const cpu_frame = try cpu.base.flushFrame();
    defer if (cpu_frame.json) |json| gpa.free(json);
    const cpu_narrow = try cpu.base.queryKey(.root, .{ .static = "narrow" });
    const cpu_wide = try cpu.base.queryKey(.root, .{ .static = "wide" });
    if (cpu_wide.visual_rect.w <= cpu_narrow.visual_rect.w * 2) return error.FixedGridMeasurement;

    const gpu = try GpuContext.create(gpa, .{
        .io = init.io,
        .extent = .{ .width = 256, .height = 96 },
        .fonts = &.{.{ .family = "Inter", .bytes = font.bytes }},
        .shaders = .{ .vert = vert.words, .frag = frag.words, .sort = sort.words },
    });
    var gpu_live = true;
    defer if (gpu_live) gpu.deinit() catch @panic("GPU context retained ownership");
    var gpu_view: View = .{};
    try gpu.base.app.mountRoot(View, &gpu_view);
    const first = try gpu.render();
    defer if (first.frame.json) |json| gpa.free(json);
    try checkPixel(first.pixels, gpu_view.lightness);
    const gpu_narrow = try gpu.base.queryKey(.root, .{ .static = "narrow" });
    const gpu_wide = try gpu.base.queryKey(.root, .{ .static = "wide" });
    if (@abs(gpu_narrow.visual_rect.w - cpu_narrow.visual_rect.w) > 0.001 or
        @abs(gpu_wide.visual_rect.w - cpu_wide.visual_rect.w) > 0.001) return error.TextGeometryMismatch;
    gpu_view.lightness = 0.55;
    const changed = try gpu.render();
    defer if (changed.frame.json) |json| gpa.free(json);
    try checkPixel(changed.pixels, gpu_view.lightness);

    const Owned = struct { value: u32 };
    var value: Owned = .{ .value = 17 };
    var owner = try gpu.base.session.create(Owned, &value);
    var owner_live = true;
    defer if (owner_live) gpu.base.session.release(Owned, &owner) catch unreachable;
    if (gpu.deinit()) |_| {
        gpu_live = false;
        owner_live = false;
        return error.LiveOwnerTeardownAccepted;
    } else |err| {
        if (err != error.LiveModels) return err;
    }
    // Core teardown closes the App but keeps the device alive for owner repair.
    if (gpu.render()) |_| return error.ClosedContextRendered else |err| {
        if (err != error.ContextClosed) return err;
    }
    try gpu.target.gpu().waitIdle();
    try gpu.base.session.release(Owned, &owner);
    owner_live = false;
    std.debug.print("test-context: no window/surface/swapchain; CPU/GPU widths {d:.3}/{d:.3}; Oklab L 0.35 -> 0.55; refused owner teardown retained the device and rejected rendering\n", .{
        gpu_narrow.visual_rect.w, gpu_wide.visual_rect.w,
    });
}
