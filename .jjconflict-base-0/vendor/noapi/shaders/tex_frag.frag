#version 450
#extension GL_EXT_nonuniform_qualifier : require

// Texture example fragment shader.
// Samples two textures from the descriptor heap and lerps between them.
// Push constant layout (24 bytes = 3 × uint64_t):
//   vertData_lo/hi: vertex data GPU address (unused here)
//   fragData_lo:    texture_a index (u32)
//   fragData_hi:    texture_b index (u32)
//   indirectData_lo: sampler index (u32)
//   indirectData_hi: fade value (f32 bitcast)

layout(location = 0) in vec2 vUv;
layout(location = 0) out vec4 fragColor;

layout(set = 0, binding = 0) uniform texture2D textures[];
layout(set = 2, binding = 0) uniform sampler samplers[];

layout(push_constant) uniform PushConstants {
    uint vertData_lo;
    uint vertData_hi;
    uint fragData_lo;
    uint fragData_hi;
    uint indirectData_lo;
    uint indirectData_hi;
};

void main() {
    uint tex_a       = fragData_lo;
    uint tex_b       = fragData_hi;
    uint sampler_idx = indirectData_lo;
    float fade       = uintBitsToFloat(indirectData_hi);

    vec4 color_a = texture(sampler2D(textures[tex_a], samplers[sampler_idx]), vUv);
    vec4 color_b = texture(sampler2D(textures[tex_b], samplers[sampler_idx]), vUv);
    fragColor = mix(color_a, color_b, fade);
}
