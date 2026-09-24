//! Scoped GPU runtime values for v7 components.
//!
//! The endpoint is persistent for the lifetime of an attached renderer. A
//! frame is a borrowed view of one active noapi command buffer. Components may
//! record work through that command buffer, but the runtime owns surface-frame
//! boundaries and queue submission.
const builtin = @import("builtin");
const noapi = @import("noapi");

/// Renderer-owned texture registration service.
///
/// The concrete registry stays in the window driver. This opaque adapter
/// keeps the core API independent of the driver's bindless heap type.
pub const TextureRegistry = struct {
    ptr: *anyopaque,
    register: *const fn (*anyopaque, noapi.TextureHandle) anyerror!u32,
    /// Unregisters a component-owned slot. Map-owned textures never call it.
    unregister: *const fn (*anyopaque, u32) void,
};

/// Persistent renderer services available to GPU lifecycle hooks.
///
/// `gpu` is owned by the window driver. `GpuEndpoint` does not expose a
/// surface, begin/end operations, or queue submission methods.
pub const GpuEndpoint = struct {
    gpu: *noapi.Gpu,
    textures: ?*TextureRegistry = null,
    /// Test-only idle override for CPU lifecycle tests without a GPU.
    /// Production builds have a zero-sized void field and always wait on noapi.
    retirement_wait_for_test: if (builtin.is_test) ?*const fn () void else void =
        if (builtin.is_test) null else {},
    /// Complete previously submitted GPU work before a batch of component
    /// unmount callbacks releases descriptor slots, shaders, or textures.
    /// The caller invokes this once per retirement batch, never per frame.
    pub fn waitForRetirement(self: *GpuEndpoint) !void {
        if (comptime builtin.is_test) {
            if (self.retirement_wait_for_test) |wait| {
                wait();
                return;
            }
        }
        try self.gpu.waitIdle();
    }

    pub fn registerTexture(self: *GpuEndpoint, texture: noapi.TextureHandle) !u32 {
        const textures = self.textures orelse return error.TextureRegistryUnavailable;
        return textures.register(textures.ptr, texture);
    }

    pub fn unregisterTexture(self: *GpuEndpoint, index: u32) void {
        const textures = self.textures orelse return;
        textures.unregister(textures.ptr, index);
    }
};

/// Borrowed context for one active renderer frame.
///
/// The pointer and its command buffer are valid only while the runtime calls a
/// component's `frameGpu` hook. Components must not retain either pointer.
pub const GpuFrame = struct {
    endpoint: *GpuEndpoint,
    command_buffer: *noapi.CommandBuffer,
    extent: noapi.Extent2D,
    frame_index: u32,
    recording: Recording = .unavailable,

    /// The host owns the Surface or offscreen Gpu. Its callback must discard
    /// the command recording, not submit component work.
    pub const Cancellation = struct {
        context: *anyopaque,
        abort: *const fn (*anyopaque, *noapi.CommandBuffer) anyerror!void,
    };

    pub const Recording = union(enum) {
        unavailable,
        active: Cancellation,
        cancelled,
        failed,
        finished,
    };

    /// App calls this before rollback releases any newly mounted GPU resource.
    /// Cancellation is terminal, including when the backend fails: callers
    /// must fail closed rather than release resources or submit this recording.
    pub fn cancelRecording(self: *GpuFrame) !void {
        const cancellation = switch (self.recording) {
            .active => |active| active,
            .cancelled => return,
            .unavailable => return error.FrameCancellationUnavailable,
            .failed => return error.FrameCancellationFailed,
            .finished => return error.FrameAlreadySubmitted,
        };
        self.recording = .failed;
        try cancellation.abort(cancellation.context, self.command_buffer);
        self.recording = .cancelled;
    }

    /// The host calls this only after submission succeeds.
    pub fn finishRecording(self: *GpuFrame) void {
        switch (self.recording) {
            .active => self.recording = .finished,
            else => @panic("GpuFrame: finishRecording without active recording"),
        }
    }
};

test "GpuFrame cancellation is once-only and terminal after failure" {
    const std = @import("std");
    const CancellationProbe = struct {
        const Self = @This();
        calls: u32 = 0,
        fail: bool = false,

        fn abort(context: *anyopaque, _: *noapi.CommandBuffer) !void {
            const probe: *Self = @ptrCast(@alignCast(context));
            probe.calls += 1;
            if (probe.fail) return error.CannotDiscardRecording;
        }
    };

    var endpoint: GpuEndpoint = undefined;
    var command: noapi.CommandBuffer = undefined;
    var probe: CancellationProbe = .{};
    var frame: GpuFrame = .{
        .endpoint = &endpoint,
        .command_buffer = &command,
        .extent = .{ .width = 1, .height = 1 },
        .frame_index = 0,
        .recording = .{ .active = .{ .context = &probe, .abort = CancellationProbe.abort } },
    };
    try frame.cancelRecording();
    try frame.cancelRecording();
    try std.testing.expectEqual(@as(u32, 1), probe.calls);
    frame.recording = .{ .active = .{ .context = &probe, .abort = CancellationProbe.abort } };
    frame.finishRecording();
    try std.testing.expectError(error.FrameAlreadySubmitted, frame.cancelRecording());

    probe.fail = true;
    frame.recording = .{ .active = .{ .context = &probe, .abort = CancellationProbe.abort } };
    try std.testing.expectError(error.CannotDiscardRecording, frame.cancelRecording());
    try std.testing.expectError(error.FrameCancellationFailed, frame.cancelRecording());
    try std.testing.expectEqual(@as(u32, 2), probe.calls);
    frame.recording = .unavailable;
    try std.testing.expectError(error.FrameCancellationUnavailable, frame.cancelRecording());
}
