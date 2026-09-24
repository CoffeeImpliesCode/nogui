#version 450
#extension GL_EXT_buffer_reference2 : require
#extension GL_EXT_shader_explicit_arithmetic_types_int64 : require

// G-buffer vertex shader.
// Reads vertex data from GPU buffer references passed via push constants.

layout(buffer_reference, std430) readonly buffer PositionBuffer { vec4  data[]; };
layout(buffer_reference, std430) readonly buffer NormalBuffer   { vec4  data[]; };
layout(buffer_reference, std430) readonly buffer UvBuffer       { vec2  data[]; };

layout(buffer_reference, std430) readonly buffer VertData {
    PositionBuffer  positions;
    NormalBuffer    normals;
    UvBuffer        uvs;
    mat4            model_to_world;
    mat4            model_to_world_normal;
    mat4            world_to_view;
    mat4            view_to_proj;
};

layout(push_constant) uniform PushBlock {
    uint64_t vertData;
    uint64_t fragData;
    uint64_t indirectData;
} push;

layout(location = 0) out vec3 vNormal;
layout(location = 1) out vec2 vUv;
layout(location = 2) out vec4 vWorldPos;

void main() {
    VertData d = VertData(push.vertData);

    vec4 pos_local = d.positions.data[gl_VertexIndex];
    vec4 world_pos = d.model_to_world * pos_local;
    vec4 view_pos  = d.world_to_view * world_pos;
    vec4 clip_pos  = d.view_to_proj * view_pos;
    gl_Position = clip_pos;

    vec4 world_normal = d.model_to_world_normal * d.normals.data[gl_VertexIndex];
    vNormal = normalize(world_normal.xyz);
    vUv = d.uvs.data[gl_VertexIndex];
    vWorldPos = world_pos;
}
