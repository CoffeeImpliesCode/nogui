// Fullscreen quad vertex shader with BDA vertex pulling.
// Each vertex is a std430-layout struct: { vec3 pos; vec2 uv; } = 24 bytes.
// The push constant contains the GPU address of the vertex array.
// gl_VertexIndex selects which vertex to read (matching the reference Slang pattern).

#version 450
#extension GL_EXT_buffer_reference2 : require
#extension GL_EXT_shader_explicit_arithmetic_types_int64 : require

// Fullscreen quad vertex shader — no vertex buffer needed.
// Generates NDC positions directly from gl_VertexIndex.
// Single triangle covers the entire [-1,1] × [-1,1] NDC area.

layout(push_constant) uniform PushBlock {
    uint64_t vertData;
    uint64_t fragData;
    uint64_t indirectData;
} push;

layout(location = 0) out vec2 vUv;

void main() {
    // Fullscreen triangle with 3 vertices (non-indexed draw):
    // V0: (-1,-1)  V1: (3,-1)  V2: (-1,3)
    float x = -1.0;
    float y = -1.0;
    if (gl_VertexIndex == 1) { x =  3.0; y = -1.0; }
    if (gl_VertexIndex == 2) { x = -1.0; y =  3.0; }
    gl_Position = vec4(x, y, 0.0, 1.0);
    vUv = gl_Position.xy * 0.5 + 0.5;
}
