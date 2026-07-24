#version 460
// Full-screen triangle vertex shader.
// Generates NDC positions from gl_VertexIndex — no vertex buffer needed.
void main() {
    // 3 vertices forming a triangle that covers the entire clip space:
    //   v0: (-1, -1), v1: (3, -1), v2: (-1, 3)
    float x = -1.0 + float(gl_VertexIndex & 1) * 4.0;
    float y = -1.0 + float((gl_VertexIndex >> 1) & 1) * 4.0;
    gl_Position = vec4(x, y, 0.0, 1.0);
}
