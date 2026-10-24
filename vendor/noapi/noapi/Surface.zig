//! Surface — unified API-level handle for a Vulkan surface + swapchain.
//! Created by `initSdl` from a platform window and that platform's own
//! surface-creation callback. The caller never holds a `VkSurfaceKHR`, so the
//! platform surface has exactly one owner and no raw handle can be handed
//! around. Delegates all per-window work to the VkBackend.

const std = @import("std");
const tracy = @import("tracy");
const Surface = @This();

const Gpu = @import("Gpu.zig").Gpu;
const vk = @import("vk.zig");
const Extent2D = @import("Extent2D.zig");
const TextureHandle = @import("TextureHandle.zig");
const CommandBuffer = @import("CommandBuffer.zig");
const FrameSchedule = @import("Gpu.zig").FrameSchedule;
const FrameResult = @import("Gpu.zig").FrameResult;
const PresentInfo = @import("Gpu.zig").PresentInfo;
const PresentFeedback = @import("Gpu.zig").PresentFeedback;

pub const PresentMode = enum(u32) {
    fifo = 0,
    mailbox = 1,
    immediate = 2,
    fifo_relaxed = 3,
};

pub const SurfaceOptions = struct {
    extent: Extent2D,
    present_mode: PresentMode = .fifo,
};

/// SDL's surface constructor ABI. Applications pass the native window and
/// this function, never a Vulkan instance or surface handle.
pub const CreateSdlSurface = *const fn (
    window: *anyopaque,
    instance: *anyopaque,
    allocator: ?*const anyopaque,
    surface: *u64,
) callconv(.c) bool;

gpu: *Gpu,
index: u32,

fn toVkPresentMode(mode: PresentMode) vk.PresentModeKHR {
    return switch (mode) {
        .fifo => .fifo_khr,
        .mailbox => .mailbox_khr,
        .immediate => .immediate_khr,
        .fifo_relaxed => .fifo_relaxed_khr,
    };
}

/// Create the platform surface for `window` and adopt it. The window and GPU
/// must outlive the returned Surface.
///
/// THE ONLY public factory, and the only owner of the `VkSurfaceKHR` it
/// makes: `deinit` destroys it on success and the `errdefer` below destroys
/// it when adoption fails, so no failure path leaks one and none destroys one
/// twice. A refused platform creation reports
/// `error.PlatformSurfaceCreationFailed` with nothing to release; a failed
/// adoption reports the backend's own error after releasing the surface.
pub fn initSdl(
    gpu: *Gpu,
    window: *anyopaque,
    create: CreateSdlSurface,
    options: SurfaceOptions,
) !Surface {
    var native_surface: u64 = 0;
    if (!create(
        window,
        @ptrFromInt(@backingInt(gpu.instanceHandle())),
        null,
        &native_surface,
    )) return error.PlatformSurfaceCreationFailed;
    const surface: vk.SurfaceKHR = @fromBackingInt(@intCast(native_surface));
    // Adoption starts here and completes inside `addWindow`, which releases
    // nothing on failure: it nulls the window's copy of the handle before
    // destroying that window, which leaves this `errdefer` the single release.
    errdefer gpu.backend.instance.destroySurfaceKHR(surface, null);
    const idx = try gpu.backend.addWindow(
        surface,
        options.extent,
        toVkPresentMode(options.present_mode),
    );
    return .{ .gpu = gpu, .index = idx };
}

pub fn deinit(self: *Surface) void {
    self.gpu.backend.removeWindow(self.index);
    self.* = undefined;
}

pub fn beginFrame(self: *Surface) !FrameSchedule {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();
    return self.gpu.backend.beginFrame(self.index);
}

pub fn endFrame(self: *Surface, present: ?PresentInfo) !FrameResult {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();
    const result = try self.gpu.backend.endFrame(self.index, present);
    return result;
}

/// Discard an active frame without submitting its recorded work. Releases the
/// acquired image with a swapchain-only transition and present. On failure,
/// the surface cannot be used again; callers must not release resources that
/// the unfinished recording may reference.
///
/// A surface frame with nothing recorded is already discarded: it reports
/// success, because hosts cancel from an `errdefer` without first checking
/// whether a submission happened. `error.FrameNotActive` is therefore NOT in
/// this contract; the caller that knows no frame began reports
/// `error.FrameNotRecording` itself.
pub fn abortFrame(self: *Surface) !void {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();
    try self.gpu.backend.abortFrame(self.index);
}

pub fn currentImage(self: *const Surface) TextureHandle {
    return self.gpu.backend.currentSwapchainImage(self.index);
}

pub fn commandsBegin(self: *Surface) CommandBuffer {
    const zone = tracy.Zone.begin(.{ .src = @src() });
    defer zone.end();
    return .{ .gpu = self.gpu, .handle = self.gpu.backend.getCurrentCmdBuf(self.index) };
}

pub fn surfaceSize(self: *const Surface) Extent2D {
    return self.gpu.backend.surfaceSize(self.index);
}

pub fn notifyResize(self: *Surface, extent: Extent2D) void {
    self.gpu.backend.notifyResize(self.index, extent);
}

/// CPU nanoseconds spent blocked on the GPU this frame (acquire/present/fence
/// waits). Resets to 0 at the start of each beginFrame. 0 if unavailable.
pub fn slopNs(self: *Surface) u64 {
    if (self.index >= self.gpu.backend.windows.items.len) return 0;
    return self.gpu.backend.windows.items[self.index].slop_ns;
}

/// True when the presentation engine reports actual presentation timestamps
/// through VK_EXT_present_timing or VK_GOOGLE_display_timing.
pub fn supportsPresentTiming(self: *const Surface) bool {
    return self.gpu.backend.presentTimingSupported(self.index);
}

/// Poll completed presentation feedback into caller storage. Never allocates
/// and never drops records: OutputTooSmall is returned before consuming any
/// driver record when the storage cannot hold all completed feedback.
pub fn pollPresentFeedback(self: *Surface, out: []PresentFeedback) !usize {
    return self.gpu.backend.pollPresentFeedback(self.index, out);
}

test {
    std.testing.refAllDecls(@This());
}
