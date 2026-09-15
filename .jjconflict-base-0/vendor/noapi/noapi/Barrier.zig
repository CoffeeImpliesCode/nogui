//! Stage-mask barrier types. Use cmd.barrier(before, after, hazards).
//! Stage is a packed struct(u64) with bits matching VkPipelineStageFlags2.
//! Hazard is a packed struct for hazard flags (descriptors, draw args, depth/stencil).

const std = @import("std");

/// Pipeline stage mask. Bit positions mirror VkPipelineStageFlags2 exactly.
/// `@bitCast` to VkPipelineStageFlags2 is valid.
pub const Stage = packed struct(u64) {
    _pad0: u3 = 0, // bits 0-2: top_of_pipe, draw_indirect, vertex_input
    vertex: bool = false, // bit 3: VERTEX_SHADER
    _pad1: u3 = 0, // bits 4-6: tess_control, tess_eval, geometry
    fragment: bool = false, // bit 7: FRAGMENT_SHADER
    _pad2: u2 = 0, // bits 8-9: early_frag_tests, late_frag_tests
    color_output: bool = false, // bit 10: COLOR_ATTACHMENT_OUTPUT
    compute: bool = false, // bit 11: COMPUTE_SHADER
    transfer: bool = false, // bit 12: ALL_TRANSFER
    _pad3: u51 = 0, // bits 13-63
};

pub const Hazard = packed struct {
    descriptors: bool = false,
    draw_arguments: bool = false,
    depth_stencil: bool = false,
};

test {
    std.testing.refAllDecls(@This());
}
