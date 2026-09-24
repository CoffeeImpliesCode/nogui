//! W23 E06 real device-diagnostics smoke.
//!
//! One noapi GPU, created through the PUBLIC loader seam
//! (`v7_frame.SystemVulkanLoader`) with no SDL, no session, no window and no
//! Vulkan surface. The backend's own device selection runs, so the metadata
//! printed here is the metadata a window host would report on this machine.
//!
//! What the run observes:
//!   1. The device does real work: a texture is allocated, a command buffer
//!      is submitted and the queue is drained, all with no surface present.
//!   2. `numSurfaces()` is zero afterwards, so nothing here opened a window
//!      and no line below describes one.
//!   3. The values the backend reported for the selected device, read back
//!      through `nogui_host.diagnostics`, with every field the run cannot
//!      source printed as `unknown`.
//!
//! What it does NOT do: verify those values against a second source. Every
//! number below is the backend's own report, so this run is a specimen of
//! what noapi reports, not proof that the report is correct. It is also not
//! evidence for E01–E05, which need the target SDK and the target itself.
//!
//! Prerequisites are the ones the offscreen shot already has: a Vulkan
//! loader on the library search path and at least one ICD, both supplied by
//! the development profile. No compositor, display server or window is
//! involved.
//!
//! Run it: `zig build w23-diagnostics-smoke`.

const std = @import("std");
const Io = std.Io;
const noapi = @import("noapi");
const frame = @import("v7_frame");
/// The host module is reached through its own root, exactly as a product
/// binary reaches it, so the diagnostic under test is the shipped one.
const diagnostics = @import("nogui_host").diagnostics;

const Reporter = struct {
    io: Io,
    buffer: [1024]u8 = [_]u8{0} ** 1024,

    fn emit(self: *Reporter, comptime fmt: []const u8, args: anytype) !void {
        // The buffer is reused for every line, so formatting into it is a
        // WRITE and the result borrows it.
        const text = try std.fmt.bufPrint(self.buffer[0..], fmt, args);
        try Io.File.stdout().writeStreamingAll(self.io, text);
    }
};

/// The smallest real device-memory transaction noapi can make without a
/// surface. A 4x4 target is enough to show the device accepted work.
const probe_extent: noapi.Extent2D = .{ .width = 4, .height = 4 };

/// Printed in place of a value the run has no source for. A backend that
/// reported nothing is not the same observation as one that reported a
/// wrong thing, and the two must not read alike.
fn orUnknown(text: []const u8) []const u8 {
    return if (text.len == 0) "unknown" else text;
}

fn subpixelText(order: ?diagnostics.SubpixelOrder) []const u8 {
    const value = order orelse return "unknown";
    return @tagName(value);
}

pub fn main(init: std.process.Init) !void {
    _ = init;
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var io_impl: Io.Threaded = .init(gpa, .{});
    defer io_impl.deinit();
    const io = io_impl.io();

    var report: Reporter = .{ .io = io };
    try report.emit("W23 E06 real device diagnostics\n", .{});
    try report.emit("window: none (no session, no SDL video, no Vulkan surface)\n", .{});

    // The loader library stays open until the GPU is destroyed: every
    // instance and device call is dispatched through code inside it.
    var loader = try frame.SystemVulkanLoader.open();
    defer loader.close();

    // The backend allocates through this allocator, so a leak here is this
    // run's own and is reported by the DebugAllocator at teardown.
    var gpu = try noapi.Gpu.init(.{
        .app_name = "w23-diagnostics-smoke",
        .validation = false,
        .loader = loader.options(),
        .io = io,
        .allocator = gpa,
    });
    defer gpu.deinit();

    const info = diagnostics.queryGpu(&gpu);

    // Metadata a device reports but cannot act on describes nothing, so the
    // run submits real work before it reports anything.
    const probe = try gpu.textureCreate(.{
        .dimensions = .{ probe_extent.width, probe_extent.height, 1 },
        .format = .rgba32_float,
        .usage = .{ .color_attachment = true, .sampled = true, .transfer_src = true },
    });
    defer gpu.textureDestroy(probe);
    const command = try gpu.commandsBegin();
    try gpu.queueSubmit(&.{command});
    try gpu.waitIdle();
    try report.emit(
        "device_work: texture {d}x{d} created, command buffer submitted, queue idle\n",
        .{ probe_extent.width, probe_extent.height },
    );

    // The count is the observation, not an intention: a non-zero value would
    // mean a surface exists that this report never described.
    const surfaces = gpu.numSurfaces();
    try report.emit("surfaces: {d}\n", .{surfaces});
    if (surfaces != 0) return error.SurfaceWithoutWindow;

    try report.emit("device.name: {s}\n", .{orUnknown(info.device.name)});
    try report.emit("device.driver: {s}\n", .{orUnknown(info.device.driver)});
    try report.emit("device.vendor_id: 0x{x}\n", .{info.device.vendor_id});
    try report.emit("device.device_id: 0x{x}\n", .{info.device.device_id});
    try report.emit("device.software_emulation: {}\n", .{info.device.software_emulation});
    try report.emit("limits.max_anisotropy: {d}\n", .{info.limits.max_anisotropy});
    try report.emit("limits.max_texture_dimension_2d: {d}\n", .{info.limits.max_texture_dimension_2d});
    try report.emit("limits.max_texture_dimension_3d: {d}\n", .{info.limits.max_texture_dimension_3d});
    try report.emit("limits.max_texture_array_layers: {d}\n", .{info.limits.max_texture_array_layers});
    try report.emit("limits.max_push_constants_size: {d}\n", .{info.limits.max_push_constants_size});
    try report.emit("limits.max_viewports: {d}\n", .{info.limits.max_viewports});
    try report.emit("limits.max_color_attachments: {d}\n", .{info.limits.max_color_attachments});
    try report.emit("limits.max_framebuffer_width: {d}\n", .{info.limits.max_framebuffer_width});
    try report.emit("limits.max_framebuffer_height: {d}\n", .{info.limits.max_framebuffer_height});
    try report.emit("limits.max_framebuffer_layers: {d}\n", .{info.limits.max_framebuffer_layers});
    try report.emit(
        "limits.max_compute_work_group_invocations: {d}\n",
        .{info.limits.max_compute_work_group_invocations},
    );
    try report.emit(
        "limits.max_compute_shared_memory_size: {d}\n",
        .{info.limits.max_compute_shared_memory_size},
    );
    try report.emit(
        "limits.min_uniform_buffer_offset_alignment: {d}\n",
        .{info.limits.min_uniform_buffer_offset_alignment},
    );
    try report.emit(
        "limits.min_storage_buffer_offset_alignment: {d}\n",
        .{info.limits.min_storage_buffer_offset_alignment},
    );
    try report.emit(
        \\limits.features: shader_object={} descriptor_buffer={} buffer_device_address={}
        \\ dynamic_rendering={} timeline_semaphore={} descriptor_indexing={}
        \\
    , .{
        info.limits.shader_object,
        info.limits.descriptor_buffer,
        info.limits.buffer_device_address,
        info.limits.dynamic_rendering,
        info.limits.timeline_semaphore,
        info.limits.descriptor_indexing,
    });
    // No display source in this run reported a subpixel order, and the run
    // does not supply one from anywhere else.
    try report.emit("subpixel_order: {s}\n", .{subpixelText(info.subpixel_order)});
}
