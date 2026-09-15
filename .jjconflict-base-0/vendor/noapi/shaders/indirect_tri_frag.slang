// Indirect triangles fragment shader.
// Simply passes through the interpolated color.

struct VertexOutput {
    float4 pos : SV_Position;
    float4 color : TEXCOORD0;
};

[shader("fragment")]
float4 fragmentMain(VertexOutput input) : SV_Target {
    return input.color;
}
