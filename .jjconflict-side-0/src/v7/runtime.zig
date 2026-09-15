//! Scoped GPU runtime values for v7 components.
//!
//! The endpoint is persistent for the lifetime of an attached renderer. A
//! frame is a borrowed view of one active noapi command buffer. Components may
//! record work through that command buffer, but the runtime owns surface-frame
//! boundaries and queue submission.
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
};
