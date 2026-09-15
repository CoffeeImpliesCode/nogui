//! Queue — GPU work submission.
const std = @import("std");
const Gpu = @import("Gpu.zig");
const CommandBuffer = @import("CommandBuffer.zig");
const Semaphore = @import("Semaphore.zig");
const Queue = @This();

gpu: *Gpu,
handle: Gpu.QueueHandle = .null_handle,

fn copyCommandBufferHandles(
    cmd_bufs: []const CommandBuffer,
    handles: *[64]Gpu.CommandBufferHandle,
) ![]Gpu.CommandBufferHandle {
    if (cmd_bufs.len > handles.len) return error.TooManyCommandBuffers;
    for (cmd_bufs, 0..) |cb, i| handles[i] = cb.handle;
    return handles[0..cmd_bufs.len];
}

pub fn submit(self: *Queue, cmd_bufs: []const CommandBuffer) !void {
    if (cmd_bufs.len == 0) return;
    var handles: [64]Gpu.CommandBufferHandle = undefined;
    const copied_handles = try copyCommandBufferHandles(cmd_bufs, &handles);
    try self.gpu.backend.queueSubmit(copied_handles);
}

pub fn submitSignal(self: *Queue, cmd_bufs: []const CommandBuffer, sem: Semaphore, value: u64) !void {
    if (cmd_bufs.len == 0) return;
    var handles: [64]Gpu.CommandBufferHandle = undefined;
    const copied_handles = try copyCommandBufferHandles(cmd_bufs, &handles);
    try self.gpu.backend.queueSubmitSignal(copied_handles, sem.handle, value);
}

pub fn submitWaitSignal(
    self: *Queue,
    cmd_bufs: []const CommandBuffer,
    wait_sem: Semaphore,
    wait_value: u64,
    signal_sem: Semaphore,
    signal_value: u64,
) !void {
    if (cmd_bufs.len == 0) return;
    var handles: [64]Gpu.CommandBufferHandle = undefined;
    const copied_handles = try copyCommandBufferHandles(cmd_bufs, &handles);
    try self.gpu.backend.queueSubmitWaitSignal(
        copied_handles,
        wait_sem.handle,
        wait_value,
        signal_sem.handle,
        signal_value,
    );
}

pub fn waitIdle(self: *Queue) !void {
    try self.gpu.backend.queueWaitIdle();
}

pub fn commandsBegin(self: *Queue, window_index: u32) CommandBuffer {
    return .{ .gpu = self.gpu, .handle = self.gpu.backend.getCurrentCmdBuf(window_index) };
}

test "task4 signaling submission wrapper accepts 64 and rejects 65 command buffers" {
    var command_buffers: [65]CommandBuffer = undefined;
    for (&command_buffers, 0..) |*command_buffer, index| {
        command_buffer.* = .{
            .gpu = undefined,
            .handle = @enumFromInt(@as(u64, @intCast(index + 1))),
        };
    }

    var handles: [64]Gpu.CommandBufferHandle = undefined;
    try std.testing.expectEqual(
        @as(usize, 64),
        (try copyCommandBufferHandles(command_buffers[0..64], &handles)).len,
    );
    try std.testing.expectError(
        error.TooManyCommandBuffers,
        copyCommandBufferHandles(command_buffers[0..65], &handles),
    );
}

test {
    std.testing.refAllDecls(@This());
}
