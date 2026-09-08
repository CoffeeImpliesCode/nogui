#version 450
#extension GL_EXT_nonuniform_qualifier : enable

// Cloud volume fragment shader.
// Raymarches through a 3D texture to render volumetric clouds.

layout(location = 0) in vec3 vWorldPos;
layout(location = 0) out vec4 fragColor;

layout(push_constant) uniform PushBlock {
    uint cloud_texture;
    uint cloud_sampler;
    float camera_x;
    float camera_y;
    float camera_z;
    float _pad0;
} pc;

// Descriptor set 0: sampled images (textures)
layout(set = 0, binding = 0) uniform texture3D texture3DHeap[];
// Descriptor set 2: samplers
layout(set = 2, binding = 0) uniform sampler samplerHeap[];

bool intersectAABB(vec3 ro, vec3 rd, vec3 bmin, vec3 bmax, out float t0, out float t1) {
    vec3 inv = 1.0 / rd;
    vec3 tbot = (bmin - ro) * inv;
    vec3 ttop = (bmax - ro) * inv;
    vec3 tmin = min(ttop, tbot);
    vec3 tmax = max(ttop, tbot);
    t0 = max(max(tmin.x, tmin.y), tmin.z);
    t1 = min(min(tmax.x, tmax.y), tmax.z);
    return t1 > max(t0, 0.0);
}

void main() {
    vec3 cam_pos = vec3(pc.camera_x, pc.camera_y, pc.camera_z);
    vec3 ray_origin = vWorldPos;
    vec3 ray_dir = normalize(vWorldPos - cam_pos);

    vec3 bmin = vec3(-0.5, -0.5, -0.5);
    vec3 bmax = vec3( 0.5,  0.5,  0.5);

    float t0, t1;
    if (!intersectAABB(ray_origin, ray_dir, bmin, bmax, t0, t1)) {
        fragColor = vec4(0.0, 0.0, 0.0, 1.0);
        return;
    }

    t0 = max(t0, 0.0);
    const int STEPS = 64;
    float step_size = (t1 - t0) / float(STEPS);

    vec3 col = vec3(0.2);
    float alpha = 0.0;
    float t = t0;

    for (int i = 0; i < STEPS; i++) {
        vec3 p = ray_origin + ray_dir * t;
        vec3 uvw = p + 0.5;

        float density = texture(
            sampler3D(texture3DHeap[nonuniformEXT(pc.cloud_texture)],
                      samplerHeap[nonuniformEXT(pc.cloud_sampler)]),
            uvw
        ).r;

        float d = density * step_size * 2.0;
        float a = (1.0 - alpha) * d;
        alpha += a;

        if (alpha > 0.95) break;
        t += step_size;
    }

    fragColor = vec4(col, alpha);
}
