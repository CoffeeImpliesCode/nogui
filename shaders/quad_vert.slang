// quad_vert.slang — 9-slice grid built in the vertex shader (P2b).
//
// No vertex buffer: the batch binds the SHARED 6-index quad
// {0,1,2,0,2,3} (base vertex 0) and one instance per SUB-QUAD
// (instance_count = rects.len * 9). SV_VertexID ∈ {0..3} selects the
// sub-quad corner (TL,TR,BR,BL — the CPU emitSceneRect qv order);
// SV_InstanceID selects the sub-quad (instance % 9) + the rect
// (instance / 9 — the instance buffer holds 9 copies per rect, so the
// hardware per-instance fetch at gl_InstanceIndex delivers rect
// instance/9's data directly). The grid, the UVs and the clip-space
// conversion reproduce the old CPU emitSceneRect arithmetic (the P0
// expansion, src/proto/render_9slice.zig) EXACTLY — same float op
// order, same literals → byte-identical clip-space positions and UVs,
// so the runShot is unchanged.
//
// Push constant ABI: PushData { vert_data @0; frag_data @8; indirect
// @16; screen @24 (framebuffer size in px) } — the fragment shader
// reads the first three fields (unchanged); screen is new (P2b).

struct PushData {
    uint64_t vert_data;
    uint64_t frag_data;
    uint64_t indirect;
    float2 screen; // framebuffer size (px) for the clip-space conversion
};

[[vk::push_constant]] PushData pc;

[shader("vertex")]
void main(
    // Instance attributes — the SceneRect (binding 1, input_rate =
    // instance). z (location 7) is declared in the pipeline but unused
    // here. The fragment outputs below keep the exact locations the
    // fragment shader expects (vClipId@5; vTexIdx@4 (P3) — location 4 was
    // skipped in the pre-P2b passthrough).
    [[vk::location(0)]] float4 rect, // dst: x, y, w, h
    [[vk::location(1)]] float4 src, // src: u, v, w, h
    [[vk::location(2)]] float4 corners, // corner_l, corner_r, corner_t, corner_b
    [[vk::location(3)]] float4 color,
    [[vk::location(4)]] float4 curve, // curve_left, curve_bottom, curve_w, curve_h
    [[vk::location(5)]] uint material_index,
    [[vk::location(6)]] uint clip_id,
    [[vk::location(8)]] float2 origin,
    [[vk::location(9)]] uint tex_idx, // bindless texture heap index (P3)
    uint vertex_index : SV_VertexID,
    uint instance_index : SV_InstanceID,
    out [[vk::location(0)]] float2 vUv,
    out [[vk::location(1)]] float4 vColor,
    out [[vk::location(2)]] nointerpolation uint vMaterialIdx,
    out [[vk::location(3)]] float2 vOrigin,
    out [[vk::location(4)]] nointerpolation uint vTexIdx, // flat (P3)
    out [[vk::location(5)]] nointerpolation uint vClipId,
    out float4 gl_Position : SV_Position)
{
    // The instance → sub-quad split: 9 sub-quads per rect, row-major
    // (0 = top-left … 8 = bottom-right — the CPU's 3×3 loop order).
    const uint subquad = instance_index % 9u;
    const uint row = subquad / 3u;
    const uint col = subquad % 3u;

    // The corner of THIS sub-quad from the shared index quad (0-3),
    // mapped to grid steps like the CPU's qv table:
    // 0 = TL (0,0), 1 = TR (1,0), 2 = BR (1,1), 3 = BL (0,1).
    const uint qx = (vertex_index == 1u || vertex_index == 2u) ? 1u : 0u;
    const uint qy = (vertex_index == 2u || vertex_index == 3u) ? 1u : 0u;

    // 3×3 grid in destination space — emitSceneRect's arithmetic verbatim.
    const float x0 = rect.x;
    const float x1 = rect.x + corners.x;
    const float x2 = rect.x + rect.z - corners.y;
    const float x3 = rect.x + rect.z;

    const float y0 = rect.y;
    const float y1 = rect.y + corners.z;
    const float y2 = rect.y + rect.w - corners.w;
    const float y3 = rect.y + rect.w;

    // Clamp to prevent overlaps (the CPU's @min/@max).
    const float x1c = min(x1, x2);
    const float x2c = max(x1, x2);
    const float y1c = min(y1, y2);
    const float y2c = max(y1, y2);

    const float xs[4] = { x0, x1c, x2c, x3 };
    const float ys[4] = { y0, y1c, y2c, y3 };
    const float px = xs[col + qx];
    const float py = ys[row + qy];

    // Clip-space conversion — (px / sw) * 2 - 1, the exact op order from
    // emitSceneRect (Vulkan NDC: Y down; layout Y down — no flip).
    const float clip_x = (px / pc.screen.x) * 2.0 - 1.0;
    const float clip_y = (py / pc.screen.y) * 2.0 - 1.0;

    // src-grid UVs (the CPU computes these unconditionally; the curve
    // branch below ignores them — same values either way).
    // Normalized corner sizes within the source UV rect.
    const float cn_l = (src.z > 0.0) ? corners.x / rect.z * src.z : 0.0;
    const float cn_r = (src.z > 0.0) ? corners.y / rect.z * src.z : 0.0;
    const float cn_t = (src.w > 0.0) ? corners.z / rect.w * src.w : 0.0;
    const float cn_b = (src.w > 0.0) ? corners.w / rect.w * src.w : 0.0;

    const float tu0 = src.x;
    const float tu1 = src.x + cn_l;
    const float tu2 = src.x + src.z - cn_r;
    const float tu3 = src.x + src.z;

    const float tv0 = src.y;
    const float tv1 = src.y + cn_t;
    const float tv2 = src.y + src.w - cn_b;
    const float tv3 = src.y + src.w;

    const float us[4] = { tu0, tu1, tu2, tu3 };
    const float vs[4] = { tv0, tv1, tv2, tv3 };

    // For glyph rects, UV = curve-space position (Y-up: 0 = baseline at
    // the bottom); otherwise the src-grid UV — emitSceneRect verbatim.
    const bool use_curve_uv = material_index > 0u && curve.z > 0.0 && curve.w > 0.0;
    const float uv_x = use_curve_uv
        ? curve.x + curve.z * (px - rect.x) / rect.z
        : us[col + qx];
    const float uv_y = use_curve_uv
        ? (curve.w + curve.y) - curve.w * (py - rect.y) / rect.w
        : vs[row + qy];

    gl_Position = float4(clip_x, clip_y, 0.0, 1.0);
    vUv = float2(uv_x, uv_y);
    vColor = color;
    vMaterialIdx = material_index;
    vOrigin = origin;
    vTexIdx = tex_idx;
    vClipId = clip_id;
}
