#version 450
#extension GL_EXT_nonuniform_qualifier : require
#extension GL_EXT_buffer_reference2 : require
#extension GL_EXT_shader_explicit_arithmetic_types_int64 : require

// Deferred shading final pass fragment shader.
// Samples G-buffer textures and displays the selected one.

layout(set = 0, binding = 0) uniform texture2D textureHeap[];
layout(set = 2, binding = 0) uniform sampler samplerHeap[];

layout(buffer_reference, std430) readonly buffer FragData {
    // Align-16 fields first (matches C struct ordering)
    vec4 v2w_right;   // right direction in world space
    vec4 v2w_up;      // up direction in world space
    vec4 v2w_fwd;     // forward direction in world space
    vec3 cam_pos;
    // Align-4 fields
    uint gbuffer_albedo;
    uint gbuffer_albedo_sampler;
    uint gbuffer_normal;
    uint gbuffer_normal_sampler;
    uint gbuffer_metallic_roughness;
    uint gbuffer_metallic_roughness_sampler;
    uint gbuffer_depth;
    uint gbuffer_depth_sampler;
    uint env_map;
    float tan_half_fov;
    float tan_half_fov_x;
    int  selected_texture_type;
};

layout(push_constant) uniform PushBlock {
    uint64_t vertData;
    uint64_t fragData;
    uint64_t indirectData;
} push;

layout(location = 0) in  vec2 vUv;
layout(location = 0) out vec4 fragColor;

void main() {
    FragData d = FragData(push.fragData);

    vec4 result;
    if (d.selected_texture_type == 0) {
        result = texture(
            sampler2D(textureHeap[nonuniformEXT(d.gbuffer_albedo)], samplerHeap[nonuniformEXT(d.gbuffer_albedo_sampler)]),
            vUv
        );
    } else if (d.selected_texture_type == 1) {
        result = texture(
            sampler2D(textureHeap[nonuniformEXT(d.gbuffer_normal)], samplerHeap[nonuniformEXT(d.gbuffer_normal_sampler)]),
            vUv
        );
    } else if (d.selected_texture_type == 2) {
        result = texture(
            sampler2D(textureHeap[nonuniformEXT(d.gbuffer_metallic_roughness)], samplerHeap[nonuniformEXT(d.gbuffer_metallic_roughness_sampler)]),
            vUv
        );
    } else {
        // Deferred shading with ray-traced environment
        vec3 albedo = texture(sampler2D(textureHeap[nonuniformEXT(d.gbuffer_albedo)], samplerHeap[nonuniformEXT(d.gbuffer_albedo_sampler)]), vUv).rgb;
        vec3 N = normalize(texture(sampler2D(textureHeap[nonuniformEXT(d.gbuffer_normal)], samplerHeap[nonuniformEXT(d.gbuffer_normal_sampler)]), vUv).xyz * 2.0 - 1.0);

        // View direction in view space from UV + FOV
        vec2 ndc = vUv * 2.0 - 1.0;
        vec3 view_dir = normalize(vec3(ndc.x * d.tan_half_fov_x, ndc.y * d.tan_half_fov, -1.0));

        // Transform view direction to world space
        vec3 world_dir = d.v2w_right.xyz * view_dir.x + d.v2w_up.xyz * view_dir.y + d.v2w_fwd.xyz * view_dir.z;

        // Reflect world direction using world-space normal
        vec3 refl_dir = reflect(world_dir, N);

        // Sample env map with reflected direction (equirectangular)
        float r = atan(refl_dir.z, refl_dir.x) / 6.2832 + 0.5;
        float s = acos(clamp(refl_dir.y, -1.0, 1.0)) / 3.1416;
        vec3 env_refl = texture(sampler2D(textureHeap[nonuniformEXT(d.env_map)], samplerHeap[nonuniformEXT(d.env_map)]), vec2(r, s)).rgb;

        // Simple directional light
        vec3 L = normalize(vec3(0.5, 0.5, 1.0));
        float diff = max(dot(N, L), 0.0);
        float amb = 0.15;
        vec3 shaded = albedo * (amb + diff * 0.85);

        // Background pixels (no cube): show env map directly
        float alpha = max(max(albedo.r, albedo.g), albedo.b);
        vec3 finalColor = mix(env_refl, shaded, clamp(alpha * 10.0, 0.0, 1.0));
        result = vec4(finalColor, 1.0);
    }

    fragColor = result;
}
