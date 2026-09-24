#version 450

// Texture sampling fragment shader.
// Samples a texture using UV coordinates from vertex shader.
// Uses noapi descriptor layout: set 0 = sampled_image, set 2 = sampler.

layout(location = 0) in vec2 vUv;
layout(location = 0) out vec4 fragColor;

layout(set = 0, binding = 0) uniform texture2D inputTexture;
layout(set = 2, binding = 0) uniform sampler inputSampler;

void main() {
    fragColor = texture(sampler2D(inputTexture, inputSampler), vUv);
}
