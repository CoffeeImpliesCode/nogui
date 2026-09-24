//! Native device diagnostics. Absent display subpixel data stays unknown.
const noapi = @import("noapi");

pub const SubpixelOrder = enum { rgb, bgr, vertical_rgb, vertical_bgr };

pub const GpuInfo = struct {
    /// Name and driver slices borrow the GPU backend's lifetime.
    device: noapi.Gpu.DeviceIdentity,
    limits: noapi.DeviceLimits,
    /// SDL does not report a reliable display subpixel order.
    subpixel_order: ?SubpixelOrder = null,
};

pub fn queryGpu(gpu: *const noapi.Gpu) GpuInfo {
    return .{
        .device = gpu.deviceIdentity(),
        .limits = gpu.deviceLimits(),
    };
}
