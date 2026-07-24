#version 460

layout(location = 0) in vec2 position;
layout(location = 1) in vec2 uv;
layout(location = 2) in vec4 color;
layout(location = 3) in uint material_idx;
layout(location = 4) in vec2 origin;

layout(location = 0) out vec2 vUv;
layout(location = 1) out vec4 vColor;
layout(location = 2) flat out uint vMaterialIdx;
layout(location = 3) flat out vec2 vOrigin;

void main() {
    gl_Position = vec4(position, 0.0, 1.0);
    vUv = uv;
    vColor = color;
    vMaterialIdx = material_idx;
    vOrigin = origin;
}
