#version 450

// Animated multi-triangle demo — vertex shader.
// Push constant: bytes 0-7 = unused, bytes 8-11 = time_sec.

layout(location = 0) out vec3 vColor;
layout(location = 1) out vec2 vUv;

layout(push_constant) uniform PushBlock {
    float _pad0;
    float _pad1;
    float time_sec;
} pc;

void main() {
    uint quad_idx = gl_VertexIndex / 6;
    uint quad_vert = gl_VertexIndex % 6;

    uint grid_w = 8;
    uint grid_h = 8;
    uint quad_x = quad_idx % grid_w;
    uint quad_y = quad_idx / grid_w;

    float cell_w = 2.0 / float(grid_w);
    float cell_h = 2.0 / float(grid_h);
    float x0 = -1.0 + float(quad_x) * cell_w;
    float y0 = -1.0 + float(quad_y) * cell_h;
    float x1 = x0 + cell_w;
    float y1 = y0 + cell_h;

    vec2 pos;
    if (quad_vert == 0) pos = vec2(x0, y0);
    else if (quad_vert == 1) pos = vec2(x1, y0);
    else if (quad_vert == 2) pos = vec2(x0, y1);
    else if (quad_vert == 3) pos = vec2(x1, y0);
    else if (quad_vert == 4) pos = vec2(x0, y1);
    else pos = vec2(x1, y1);

    vUv = pos * 0.5 + 0.5;

    float t = pc.time_sec;
    float r = sin(float(quad_x) * 0.5 + t) * 0.5 + 0.5;
    float g = cos(float(quad_y) * 0.5 + t * 1.3) * 0.5 + 0.5;
    float b = sin(float(quad_x + quad_y) * 0.3 + t * 0.7) * 0.5 + 0.5;

    uint cx = grid_w / 2;
    uint cy = grid_h / 2;
    if (quad_x == cx && quad_y == cy) {
        float p = sin(t * 3.0) * 0.5 + 0.5;
        vColor = vec3(p + 0.5);
    } else {
        vColor = vec3(r, g, b);
    }

    gl_Position = vec4(pos, 0.0, 1.0);
}
