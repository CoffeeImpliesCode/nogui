#version 460
// Blit pass: sample Oklab render target, convert to linear sRGB.
// Uses separate texture+sampler descriptors (set 0 = image, set 2 = sampler).

layout(set = 0, binding = 0) uniform texture2D uRenderTarget;
layout(set = 2, binding = 0) uniform sampler uBlitSampler;

layout(location = 0) out vec4 fragColor;

vec3 oklabToSRGB(vec3 lab) {
    float l_ = lab.x + 0.3963377774 * lab.y + 0.2158037573 * lab.z;
    float m_ = lab.x - 0.1055613458 * lab.y - 0.0638541728 * lab.z;
    float s_ = lab.x - 0.0894841775 * lab.y - 1.2914855480 * lab.z;
    vec3 lms = vec3(l_, m_, s_) * vec3(l_, m_, s_) * vec3(l_, m_, s_);
    return vec3(
        +4.0767416621 * lms.x - 3.3077115913 * lms.y + 0.2309699292 * lms.z,
        -1.2684380046 * lms.x + 2.6097574011 * lms.y - 0.3413193965 * lms.z,
        -0.0041960863 * lms.x - 0.7034186147 * lms.y + 1.7076147010 * lms.z
    );
}

void main() {
    vec4 oklab = texelFetch(sampler2D(uRenderTarget, uBlitSampler), ivec2(gl_FragCoord.xy), 0);
    vec3 srgb = oklabToSRGB(oklab.xyz);
    fragColor = vec4(srgb, 1.0);
}
