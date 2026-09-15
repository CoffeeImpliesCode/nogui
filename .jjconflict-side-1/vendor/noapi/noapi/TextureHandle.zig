//! Opaque handle for a GPU texture.
//! Two variants: real pooled textures and per-window swapchain images.
//! Use .isSwapchain() to check variant, then access .texture or .swapchain.

const TextureHandle = @This();

pub const TextureData = struct { id: u32, birth_frame: u16 };
pub const SwapchainData = struct { window_index: u32, image_index: u32 };

pub const Tag = enum(u2) { texture, swapchain };

tag: Tag = .texture,
texture: TextureData = .{ .id = 0, .birth_frame = 0 },
swapchain: SwapchainData = .{ .window_index = 0, .image_index = 0 },

pub fn isSwapchain(self: TextureHandle) bool {
    return self.tag == .swapchain;
}
