#version 450

// Texture example vertex shader.
// Reads position + UV from vertex buffer attributes.

layout(location = 0) in vec2 position;
layout(location = 1) in vec2 uv;

layout(location = 0) out vec2 vUv;

void main() {
    gl_Position = vec4(position, 0.0, 1.0);
    vUv = uv;
}
