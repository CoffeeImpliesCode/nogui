// Full-screen triangle vertex shader (ported from fullscreen.vert).
// Generates NDC positions from gl_VertexIndex — no vertex buffer needed.

[shader("vertex")]
float4 main(uint vid : SV_VertexID) : SV_Position {
    // 3 vertices forming a triangle that covers the entire clip space:
    //   v0: (-1, -1), v1: (3, -1), v2: (-1, 3)
    float x = -1.0 + float(vid & 1u) * 4.0;
    float y = -1.0 + float((vid >> 1) & 1u) * 4.0;
    return float4(x, y, 0.0, 1.0);
}
