//! GPU error set and memory type.
const std = @import("std");

pub const GpuError = error{
    OutOfMemory,
    DeviceLost,
    SurfaceInvalid,
    ShaderCompileFailed,
    InvalidHandle,
    BackendError,
    /// Swapchain is out of date; recreate it. Not a failure.
    OutOfDateKHR,
};

pub const MemoryType = enum(u2) { default = 0, gpu = 1, readback = 2 };

test {
    std.testing.refAllDecls(@This());
}
