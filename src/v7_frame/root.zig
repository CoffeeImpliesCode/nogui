//! Reusable GUI scene lowering and GPU text, independent of native windows.
const text_gpu = @import("text_gpu.zig");
/// GPU command-buffer types in the public offscreen API.
pub const noapi = @import("noapi");

pub const TextEngine = text_gpu.TextEngine;
pub const srgbToOklab = text_gpu.srgbToOklab;
pub const max_materials = text_gpu.max_materials;
pub const font_size_px = text_gpu.font_size_px;
pub const scene = @import("scene.zig");
pub const heap = @import("heap.zig");
pub const BindlessHeap = heap.BindlessHeap;
pub const offscreen = @import("offscreen.zig");
pub const Offscreen = offscreen.Offscreen;
pub const native = @import("native.zig");
pub const NativeFrame = native.NativeFrame;
pub const writePpm = offscreen.writePpm;
pub const loader = @import("loader.zig");
pub const SystemVulkanLoader = loader.SystemVulkanLoader;

test {
    _ = @import("text_gpu.zig");
    _ = @import("scene.zig");
    _ = @import("heap.zig");
    _ = @import("offscreen.zig");
    _ = @import("loader.zig");
    _ = @import("native.zig");
}
