// Indirect triangles vertex shader.
// Reads shared vertex data from push constant vertData pointer,
// per-draw data (color, pos, size) from indirectData pointer indexed by SV_DrawIndex.

struct Vertex {
    float3 pos;
};

struct VertexData {
    Vertex* verts;
};

struct PerDrawData {
    float3 color;
    float3 pos;
    float size;
};

// Must match DrawIndexedIndirectCommand + PerDrawData layout
struct DrawCommand {
    uint indexCount;
    uint instanceCount;
    uint firstIndex;
    int  vertexOffset;
    uint firstInstance;
    PerDrawData data;
};

struct __PushConstants_Graphics {
    uint64_t vertData;
    uint64_t fragData;
    uint64_t indirectData;
};

[[vk::push_constant]] __PushConstants_Graphics __push_graphics;

struct VertexOutput {
    float4 pos : SV_Position;
    float4 color : TEXCOORD0;
};

[shader("vertex")]
VertexOutput vertexMain(uint vert_id : SV_VertexID, uint draw_id : SV_DrawIndex) {
    VertexOutput output;

    VertexData* vert_data = (VertexData*)__push_graphics.vertData;
    DrawCommand* draw_cmds = (DrawCommand*)__push_graphics.indirectData;
    PerDrawData per_draw = draw_cmds[draw_id].data;

    output.pos = float4(vert_data.verts[vert_id].pos * per_draw.size + per_draw.pos, 1.0);
    output.color = float4(per_draw.color, 1.0);

    return output;
}
