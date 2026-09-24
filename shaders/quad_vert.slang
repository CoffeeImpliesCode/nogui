// quad_vert.slang — 9-slice grid built in the vertex shader (P2b), now
// drawn THROUGH the sorted permutation (V1b).
//
// No vertex buffer and no instance attributes: the batch binds the SHARED
// 6-index quad {0,1,2,0,2,3} (base vertex 0) and one instance per
// SUB-QUAD (instance_count = bag_len * 9). SV_VertexID ∈ {0..3} selects
// the sub-quad corner (TL,TR,BR,BL — the CPU emitSceneRect qv order);
// SV_InstanceID selects the sub-quad (instance % 9) + the drawable
// (instance / 9). The drawable's SceneRect is NOT a vertex attribute
// anymore: CS1 (sort.comp.slang) has sorted the permutation
// perm[drawable_index] = the bag slot in paint order, and the VS fetches
// bag[perm[instance / 9]] through the physical-storage-buffer pointers
// carried in the push constant (scene_bda + perm_bda — the zero-descriptor
// BDA transport the material buffer already uses). The grid, the UVs and
// the clip-space conversion reproduce the old CPU emitSceneRect arithmetic
// EXACTLY — same float op order, same literals → byte-identical
// clip-space positions and UVs, so the runShot is unchanged when the sort
// is the identity (the paint-ordered bag).
//
// Push constant ABI: PushData { vert_data @0; frag_data @8; indirect @16
// (clip-rect buffer BDA); screen @24 (logical window size); scene_bda @32
// (the drawable bag); perm_bda @40 (the sorted permutation); pixel_scale
// @48 (device pixels per logical unit) }. The fragment shader uses the
// same full declaration and converts SV_Position to logical coordinates.

struct SceneRect {
    float4 dst;           // 0
    float4 src;           // 16
    float4 corners;       // 32
    float4 color;         // 48
    float4 curve;         // 64
    uint material_index;  // 80
    uint clip_id;         // 84
    uint z;               // 88 (unused here — the CS1 sort key)
    uint origin_x;        // 92
    uint origin_y;        // 96
    uint tex_idx;         // 100
    uint order;           // 104 (unused here — the CS1 tiebreaker)
    // implicit pad to 112 (the 16-aligned bag stride)
};

struct GlyphMaterial {
    int type;
    float bearing_y;
    float curve_w;
    float curve_h;
    float win_w;
    float win_h;
    uint64_t curve_bda;
    uint64_t band_bda;
    float4 gradient_to;
};

struct PaintTransform {
    float4 transform_x;
    float4 transform_y;
};

struct PushData {
    uint64_t vert_data;
    uint64_t frag_data;
    uint64_t indirect;
    float2 screen; // logical window size for the clip-space conversion
    uint64_t scene_bda; // the drawable bag (CS1's input, read here sorted)
    uint64_t perm_bda; // the sorted permutation (u32 bag indices)
    float2 pixel_scale; // physical framebuffer pixels per logical unit
};

[[vk::push_constant]] PushData pc;

[shader("vertex")]
void main(
    uint vertex_index : SV_VertexID,
    uint instance_index : SV_InstanceID,
    out [[vk::location(0)]] float2 vUv,
    out [[vk::location(1)]] float4 vColor,
    out [[vk::location(2)]] nointerpolation uint vMaterialIdx,
    out [[vk::location(3)]] float2 vOrigin,
    out [[vk::location(4)]] nointerpolation uint vTexIdx, // flat (P3)
    out [[vk::location(5)]] nointerpolation uint vClipId,
    out [[vk::location(6)]] float2 vLocal,
    out float4 gl_Position : SV_Position)
{
    // The instance → drawable split: 9 sub-quads per rect, row-major
    // (0 = top-left … 8 = bottom-right — the CPU's 3×3 loop order), then
    // the permutation: perm[drawable] = the bag slot in paint order
    // (CS1's output; the identity on the paint-ordered bag).
    const uint subquad = instance_index % 9u;
    const uint rect_idx = instance_index / 9u;
    const uint bag_idx = vk::BufferPointer<uint>(pc.perm_bda + 4u * rect_idx).Get();
    SceneRect r = vk::BufferPointer<SceneRect>(pc.scene_bda + 112u * uint64_t(bag_idx)).Get();
    const uint row = subquad / 3u;
    const uint col = subquad % 3u;

    // The corner of THIS sub-quad from the shared index quad (0-3),
    // mapped to grid steps like the CPU's qv table:
    // 0 = TL (0,0), 1 = TR (1,0), 2 = BR (1,1), 3 = BL (0,1).
    const uint qx = (vertex_index == 1u || vertex_index == 2u) ? 1u : 0u;
    const uint qy = (vertex_index == 2u || vertex_index == 3u) ? 1u : 0u;

    // 3×3 grid in destination space — emitSceneRect's arithmetic verbatim.
    const float x0 = r.dst.x;
    const float x1 = r.dst.x + r.corners.x;
    const float x2 = r.dst.x + r.dst.z - r.corners.y;
    const float x3 = r.dst.x + r.dst.z;

    const float y0 = r.dst.y;
    const float y1 = r.dst.y + r.corners.z;
    const float y2 = r.dst.y + r.dst.w - r.corners.w;
    const float y3 = r.dst.y + r.dst.w;

    // Clamp to prevent overlaps (the CPU's @min/@max).
    const float x1c = min(x1, x2);
    const float x2c = max(x1, x2);
    const float y1c = min(y1, y2);
    const float y2c = max(y1, y2);

    const float xs[4] = { x0, x1c, x2c, x3 };
    const float ys[4] = { y0, y1c, y2c, y3 };
    const float px = xs[col + qx];
    const float py = ys[row + qy];

    // Clip-space conversion uses the logical window extents. Rasterization
    // maps this projection to the physical viewport exactly once (Vulkan
    // NDC: Y down; layout Y down — no flip).
    float2 painted = float2(px, py);
    if (r.curve.x > 1e30) {
        GlyphMaterial material = vk::BufferPointer<GlyphMaterial>(
            pc.vert_data + 56u * uint64_t(r.material_index)).Get();
        PaintTransform transform = vk::BufferPointer<PaintTransform>(material.curve_bda).Get();
        painted = float2(
            transform.transform_x.x * px + transform.transform_x.y * py + transform.transform_x.z,
            transform.transform_y.x * px + transform.transform_y.y * py + transform.transform_y.z);
    }
    const float clip_x = (painted.x / pc.screen.x) * 2.0 - 1.0;
    const float clip_y = (painted.y / pc.screen.y) * 2.0 - 1.0;

    // src-grid UVs (the CPU computes these unconditionally; the curve
    // branch below ignores them — same values either way).
    // Normalized corner sizes within the source UV rect.
    const float cn_l = (r.src.z > 0.0) ? r.corners.x / r.dst.z * r.src.z : 0.0;
    const float cn_r = (r.src.z > 0.0) ? r.corners.y / r.dst.z * r.src.z : 0.0;
    const float cn_t = (r.src.w > 0.0) ? r.corners.z / r.dst.w * r.src.w : 0.0;
    const float cn_b = (r.src.w > 0.0) ? r.corners.w / r.dst.w * r.src.w : 0.0;

    const float tu0 = r.src.x;
    const float tu1 = r.src.x + cn_l;
    const float tu2 = r.src.x + r.src.z - cn_r;
    const float tu3 = r.src.x + r.src.z;

    const float tv0 = r.src.y;
    const float tv1 = r.src.y + cn_t;
    const float tv2 = r.src.y + r.src.w - cn_b;
    const float tv3 = r.src.y + r.src.w;

    const float us[4] = { tu0, tu1, tu2, tu3 };
    const float vs[4] = { tv0, tv1, tv2, tv3 };

    // For glyph rects, UV = curve-space position (Y-up: 0 = baseline at
    // the bottom); otherwise the src-grid UV — emitSceneRect verbatim.
    const bool use_curve_uv = r.material_index > 0u && r.curve.z > 0.0 && r.curve.w > 0.0;
    const float uv_x = use_curve_uv
        ? r.curve.x + r.curve.z * (px - r.dst.x) / r.dst.z
        : us[col + qx];
    const float uv_y = use_curve_uv
        ? (r.curve.w + r.curve.y) - r.curve.w * (py - r.dst.y) / r.dst.w
        : vs[row + qy];

    gl_Position = float4(clip_x, clip_y, 0.0, 1.0);
    vUv = float2(uv_x, uv_y);
    vColor = r.color;
    vMaterialIdx = r.material_index;
    vOrigin = float2(asfloat(r.origin_x), asfloat(r.origin_y));
    vTexIdx = r.tex_idx;
    vClipId = r.clip_id;
    vLocal = float2(px, py);
}
