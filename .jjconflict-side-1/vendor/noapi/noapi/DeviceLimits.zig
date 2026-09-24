// zlint-disable unused-decls -- public API type, re-exported via root.zig
//! Device limits — GPU capabilities queried at init time.
const std = @import("std");
const DeviceLimits = @This();

max_anisotropy: f32 = 16.0,
max_texture_dimension_2d: u32 = 16384,
max_texture_dimension_3d: u32 = 2048,
max_texture_array_layers: u32 = 2048,
max_push_constants_size: u32 = 128,
max_viewports: u32 = 16,
max_color_attachments: u32 = 8,
max_framebuffer_width: u32 = 16384,
max_framebuffer_height: u32 = 16384,
max_framebuffer_layers: u32 = 2048,
max_compute_work_group_invocations: u32 = 1024,
max_compute_shared_memory_size: u32 = 49152,
min_uniform_buffer_offset_alignment: u32 = 256,
min_storage_buffer_offset_alignment: u32 = 256,
shader_object: bool = true,
descriptor_buffer: bool = false,
buffer_device_address: bool = true,
dynamic_rendering: bool = true,
timeline_semaphore: bool = true,
descriptor_indexing: bool = true,

test {
    std.testing.refAllDecls(@This());
}
