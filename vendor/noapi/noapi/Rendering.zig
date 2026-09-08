// zlint-disable unused-decls -- public API type, re-exported via root.zig
//! Rendering attachment description for dynamic rendering.
const std = @import("std");
const TextureHandle = @import("TextureHandle.zig");
const Rendering = @This();

pub const LoadOp = enum(u2) {
    load = 0,
    clear = 1,
    dont_care = 2,
};

pub const StoreOp = enum(u2) {
    store = 0,
    dont_care = 1,
};

pub const RenderingAttachment = struct {
    texture: TextureHandle = .{ .texture = .{ .id = 0, .birth_frame = 0 } },
    load_op: LoadOp = .clear,
    store_op: StoreOp = .store,
    clear_color: [4]f32 = .{ 0, 0, 0, 1 },
    clear_depth: f32 = 1.0,
    clear_stencil: u32 = 0,
    resolve_texture: ?TextureHandle = null,
};

render_area_offset: [2]i32 = .{ 0, 0 },
render_area_size: [2]u32 = .{ 800, 600 },
layer_count: u32 = 1,
view_mask: u32 = 0,
color_attachments: []const RenderingAttachment = &.{},
depth_attachment: ?RenderingAttachment = null,
stencil_attachment: ?RenderingAttachment = null,

test {
    std.testing.refAllDecls(@This());
}
