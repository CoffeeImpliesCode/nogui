//! Vertex input types — shared between CommandBuffer and VkBackend.

const std = @import("std");

pub const VertexBinding = struct { binding: u32, stride: u32, input_rate: u32 };
pub const VertexAttribute = struct { location: u32, binding: u32, format: u32, offset: u32 };

test {
    std.testing.refAllDecls(@This());
}
