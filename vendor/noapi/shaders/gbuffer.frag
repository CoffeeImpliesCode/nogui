#version 450
#extension GL_EXT_nonuniform_qualifier : require
#extension GL_EXT_buffer_reference2 : require
#extension GL_EXT_shader_explicit_arithmetic_types_int64 : require

// G-buffer fragment shader — outputs to multiple render targets.
// Uses descriptor heap for texture sampling.

layout(set = 0, binding = 0) uniform texture2D textureHeap[];
layout(set = 2, binding = 0) uniform sampler samplerHeap[];

layout(buffer_reference, std430) readonly buffer FragData {
    uint base_color_map;
    uint base_color_map_sampler;
    uint metallic_roughness_map;
    uint metallic_roughness_map_sampler;
    uint normal_map;
    uint normal_map_sampler;
};

layout(push_constant) uniform PushBlock {
    uint64_t vertData;
    uint64_t fragData;
    uint64_t indirectData;
} push;

layout(location = 0) in  vec3 vNormal;
layout(location = 1) in  vec2 vUv;
layout(location = 2) in  vec4 vWorldPos;

layout(location = 0) out vec4 outAlbedo;
layout(location = 1) out vec4 outNormal;
layout(location = 2) out vec4 outMetallicRoughness;

void main() {
    FragData d = FragData(push.fragData);

    vec4 base_color = texture(
        sampler2D(textureHeap[nonuniformEXT(d.base_color_map)], samplerHeap[nonuniformEXT(d.base_color_map_sampler)]),
        vUv
    );
    if (base_color.a < 0.1) discard;

    // Pack world normal into [0, 1] range for G-buffer storage
    vec3 world_normal = normalize(vNormal);
    vec4 packed_normal = vec4(world_normal * 0.5 + 0.5, 1.0);

    vec4 mr_sample = texture(
        sampler2D(textureHeap[nonuniformEXT(d.metallic_roughness_map)], samplerHeap[nonuniformEXT(d.metallic_roughness_map_sampler)]),
        vUv
    );

    outAlbedo = base_color;
    outNormal = packed_normal;
    outMetallicRoughness = mr_sample;
}
