#version 450

// Fullscreen quad vertex shader.
// Generates a fullscreen quad from gl_VertexIndex (0-5, two triangles).
// Outputs UV coordinates for texture sampling.

layout(location = 0) out vec2 vUv;

void main() {
    // Two triangles forming a fullscreen quad:
    // 0: (-1,-1)  1: (1,-1)  2: (-1,1)
    // 3: (1,-1)   4: (-1,1)  5: (1,1)
    float x = (gl_VertexIndex == 1 || gl_VertexIndex == 3 || gl_VertexIndex == 5) ? 1.0 : -1.0;
    float y = (gl_VertexIndex == 2 || gl_VertexIndex == 4) ? 1.0 : -1.0;
    gl_Position = vec4(x, y, 0.0, 1.0);
    vUv = vec2(x * 0.5 + 0.5, y * 0.5 + 0.5);
}
