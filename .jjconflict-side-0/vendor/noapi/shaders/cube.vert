#version 450
#extension GL_EXT_buffer_reference : require
#extension GL_EXT_shader_explicit_arithmetic_types : require

// Per-frame data stored in a GPU buffer, accessed via buffer device address.
// The address is passed through the vert_data push constant (u64).
layout(buffer_reference, std430, buffer_reference_align=16) buffer PerFrameData {
    vec4 positions[24];
    vec4 colors[24];
    mat4 model_to_world;
    mat4 world_to_view;
    mat4 view_to_proj;
};

layout(push_constant) uniform PushBlock {
    uint64_t vert_data;
} pc;

layout(location = 0) out vec3 vColor;

void main() {
    PerFrameData ref = PerFrameData(pc.vert_data);
    vec4 pos = ref.positions[gl_VertexIndex];
    vec4 color = ref.colors[gl_VertexIndex];

    gl_Position = ref.view_to_proj * ref.world_to_view * ref.model_to_world * pos;
    // gl_Position.z = -gl_Position.z;

    vColor = color.xyz;
}
