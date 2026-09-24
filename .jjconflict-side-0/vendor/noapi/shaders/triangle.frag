#version 450

// Minimal fragment shader matching no_gfx_api convention.
// Receives interpolated color from vertex shader via location 0.

layout(location = 0) in vec3 vColor;
layout(location = 0) out vec4 fragColor;

void main() {
    fragColor = vec4(vColor, 1.0);
}
