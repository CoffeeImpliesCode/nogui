#version 450
// Cloud volume vertex shader.
// Generates a unit cube from gl_VertexIndex (no vertex buffer needed).
// Camera position comes from push constants; view/proj computed in shader.

layout(location = 0) out vec3 vWorldPos;

layout(push_constant) uniform PushBlock {
    uint cloud_texture;
    uint cloud_sampler;
    float camera_x;
    float camera_y;
    float camera_z;
    float _pad0;
} pc;

// Unit cube — 36 explicit vertices (12 triangles, 6 faces × 2 tris).
// Using triangle_list (3 verts per tri), indexed by gl_VertexIndex.
// Face winding: CCW for front face when viewed from outside.
const vec3 cube_verts[36] = vec3[](
    // +X face (right), looking from +X
    vec3( 0.5, -0.5, -0.5), vec3( 0.5,  0.5, -0.5), vec3( 0.5,  0.5,  0.5),
    vec3( 0.5, -0.5, -0.5), vec3( 0.5,  0.5,  0.5), vec3( 0.5, -0.5,  0.5),
    // -X face (left)
    vec3(-0.5, -0.5,  0.5), vec3(-0.5,  0.5,  0.5), vec3(-0.5,  0.5, -0.5),
    vec3(-0.5, -0.5,  0.5), vec3(-0.5,  0.5, -0.5), vec3(-0.5, -0.5, -0.5),
    // +Y face (y=+0.5, normal +Y), CCW from +Y
    vec3(-0.5,  0.5, -0.5), vec3( 0.5,  0.5,  0.5), vec3( 0.5,  0.5, -0.5),
    vec3(-0.5,  0.5, -0.5), vec3(-0.5,  0.5,  0.5), vec3( 0.5,  0.5,  0.5),
    // -Y face (y=-0.5, normal -Y), CCW from -Y
    vec3(-0.5, -0.5,  0.5), vec3( 0.5, -0.5, -0.5), vec3( 0.5, -0.5,  0.5),
    vec3(-0.5, -0.5,  0.5), vec3(-0.5, -0.5, -0.5), vec3( 0.5, -0.5, -0.5),
    // +Z face (z=+0.5, normal +Z), CCW from +Z
    vec3(-0.5, -0.5,  0.5), vec3( 0.5,  0.5,  0.5), vec3(-0.5,  0.5,  0.5),
    vec3(-0.5, -0.5,  0.5), vec3( 0.5, -0.5,  0.5), vec3( 0.5,  0.5,  0.5),
    // -Z face (z=-0.5, normal -Z), CCW from -Z
    vec3(-0.5, -0.5, -0.5), vec3( 0.5,  0.5, -0.5), vec3( 0.5, -0.5, -0.5),
    vec3(-0.5, -0.5, -0.5), vec3(-0.5,  0.5, -0.5), vec3( 0.5,  0.5, -0.5)
);

void main() {
    vec3 pos = cube_verts[gl_VertexIndex];
    vec3 cam_pos = vec3(pc.camera_x, pc.camera_y, pc.camera_z);
    vec3 forward = normalize(-cam_pos);
    vec3 world_up = vec3(0.0, 0.0, 1.0);
    vec3 right = normalize(cross(world_up, forward));
    vec3 up = cross(right, forward);

    mat4 view = mat4(
        vec4(right.x, up.x, -forward.x, 0.0),
        vec4(right.y, up.y, -forward.y, 0.0),
        vec4(right.z, up.z, -forward.z, 0.0),
        vec4(-dot(right, cam_pos), -dot(up, cam_pos), dot(forward, cam_pos), 1.0)
    );

    float fov = 1.047;
    float aspect = 1.0;
    float near = 0.1;
    float far = 100.0;
    float f = 1.0 / tan(fov * 0.5);
    mat4 proj = mat4(
        vec4(f / aspect, 0.0, 0.0, 0.0),
        vec4(0.0, f, 0.0, 0.0),
        vec4(0.0, 0.0, -far / (far - near), -1.0),
        vec4(0.0, 0.0, -far * near / (far - near), 0.0)
    );

    vec4 clip_pos = proj * view * vec4(pos, 1.0);
    clip_pos.y = -clip_pos.y;
    gl_Position = clip_pos;
    vWorldPos = pos;
}
