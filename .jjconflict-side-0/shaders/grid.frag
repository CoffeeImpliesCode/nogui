#version 450

layout(location = 0) in vec3 vColor;
layout(location = 1) in vec2 vUv;
layout(location = 0) out vec4 fragColor;

layout(push_constant) uniform PushBlock {
    float _pad0;
    float _pad1;
    float time_sec;
} pc;

void main() {
    float vignette = 1.0 - length(vUv - 0.5) * 0.6;
    fragColor = vec4(vColor * vignette, 1.0);
}
