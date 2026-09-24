// 9-slice fragment pass. Preserve float operation order for pixel parity.
// Glyph coverage and color conversions share the helpers in lib/coverage
// and lib/color. The vertex interface and push-constant offsets are the
// renderer contract:
//
// Entry: main (fragment) — the runtime loads the .spv with entry "main".
// Vertex interface (locations in GLSL order): vUv@0, vColor@1,
// vMaterialIdx@2 (flat), vOrigin@3, vTexIdx@4 (flat, NEW — the bindless
// texture heap index; ~0 = none, P3), vClipId@5 (flat, NEW — the clip-rect
// index; ~0 = none); SV_Position carries gl_FragCoord.
// Push constant ABI: vert_data @0, frag_data @8, indirect @16 (logical clip
// rect BDA), screen @24 (logical window size), scene_bda @32, perm_bda @40,
// pixel_scale @48 (physical framebuffer pixels per logical unit).
//
import lib.color;
import lib.coord;
import lib.coverage;

static const int TYPE_SOLID = 0;
static const int TYPE_GLYPH = 1;
static const int TYPE_ROUNDED_RECT = 2;
static const int TYPE_SHADOW = 3;
static const int TYPE_STROKE = 4;
static const int TYPE_SWEEP = 5; // the SVG fill: the SDF AA, no subpixel
static const int TYPE_PATH_FILL = 6;
static const int TYPE_PAINT_RECT = 7;
static const int TYPE_PAINT_SHADOW = 8;
static const int TYPE_PATH_STROKE = 9;


// The coverage gamma (Blinn's compositing practice): the alpha is NOT the
// literal sub-pixel area — pow(cov, 1/GAMMA) raises the low coverages so
// sub-pixel features (the tiger's 0.02-1px strokes) read as ink instead
// of faint gray, while the wide shapes (cov = 1) are untouched. 1.6 is
// the lighter end of the usual 1.6-2.2 range.
static const float COVERAGE_GAMMA = 1.6;

// The SVG fill sweep window spans SWEEP_WINDOW device pixels (1.0 is
// the exact physical pixel). Dividing by pixel_scale keeps the analytic
// integration in the same logical units as the curves.
static const float SWEEP_WINDOW = 2.0;

// GlyphMaterial GPU ABI (56 bytes):
// int type @0; float bearing_y/curve_w/curve_h/win_w/win_h @4..24;
// uint64_t curve_bda @24; uint64_t band_bda @32; float4 gradient_to @40.
// Field order MUST match src/v7_render/sweeper.zig.
struct GlyphMaterial {
    int type;
    float bearing_y;
    float curve_w;
    float curve_h;
    float win_w;
    float win_h;
    uint64_t curve_bda;
    uint64_t band_bda; // the fill-band buffer BDA (TYPE_SWEEP); 0 = none
    float4 gradient_to; // gradient bottom color (Oklab); .w > 0 enables the gradient
};
// W13 payload lives in the renderer's three-slot ring. Sixteen 16-byte vectors.
struct PaintExtra {
    float4 transform_x;
    float4 transform_y;
    float4 size;
    float4 radii;
    float4 border_width;
    float4 border_top;
    float4 border_right;
    float4 border_bottom;
    float4 border_left;
    uint4 border_styles;
    float4 from;
    float4 to;
    float4 gradient;
    float4 pattern;
    float4 shadow;
    uint4 mode;
};


struct QuadCurve {
    float2 p0;
    float2 p1;
    float2 p2;
};

// Curve buffer header. Access ONLY via the BufferPointer + curveAt below —
// never copy CurveBuf by value, && NEVER use a member array: Slang emits
// a wrong ArrayStride for arrays in physical-storage-buffer structs (8 for
// the unsized form, 98312 = the whole struct for the fixed form), so the
// sweep would read garbage. curveAt builds a fresh BufferPointer per
// element — the address arithmetic is the contract: header 8 bytes
// ([u32 count][u32 pad]), then 24-byte QuadCurves.
struct CurveBuf {
    uint num_curves;
    uint pad;
};

// The per-path fill-band buffer (the TYPE_SWEEP optimization), 32-byte
// header: float4 interior_rect @0 (the conservative interior box in the
// sweep space; w <= 0 or h <= 0 = the interior early-out disabled),
// int row_base @16 (the first band row), uint row_count @20,
// uint pairs_base @24 (the u32 offset of the (offset,count) pair array),
// uint indices_base @28 (the u32 offset of the curve-index payload).
// Then row_count (offset, count) u32 pairs, then the concatenated u32
// curve indices (ascending curve order — the banded sum is bit-identical
// to the full loop). All offsets are u32 offsets into this buffer.
struct BandHeader {
    float4 interior_rect;
    int row_base;
    uint row_count;
    uint pairs_base;
    uint indices_base;
};

// The stroke's offset-outline polygon (the exact Cairo reference, mode 2):
// the edges of the band's boundary, each a straight segment (x0,y0)->(x1,y1).
// Layout like the curve buffer: a u32 count header, then 16-byte Edges.
struct Edge {
    float2 p0;
    float2 p1;
};

struct EdgeBuf {
    uint count;
    uint pad;
};

Edge edgeAt(uint64_t bda, uint i) {
    return vk::BufferPointer<Edge>(bda + 8 + 16 * i).Get();
}

QuadCurve curveAt(uint64_t curve_bda, uint i) {
    return vk::BufferPointer<QuadCurve>(curve_bda + 8 + 24 * i).Get();
}

// Push constant. The full declaration matches the vertex shader, with
// pixel_scale at byte 48 even though the fragment does not read screen
// or the drawable/permutation BDAs.
struct PushData {
    uint64_t vert_data;
    uint64_t frag_data;
    uint64_t indirect;
    float2 screen;
    uint64_t scene_bda;
    uint64_t perm_bda;
    float2 pixel_scale;
};

// Clip rects are logical window units, stored verbatim in 16-byte entries.
// An extent of -1 disables that axis; ~0 vClipId bypasses the lookup.
struct ClipRect {
    float x;
    float y;
    float w;
    float h;
};

[[vk::push_constant]] PushData pc;

// Bindless texture heap (P3, §5 phase 1): the noapi GUI texture heap's
// set 0 (textures) + set 2 (samplers) — the same sets the blit heap uses.
// The window's TextureRegistry registers each app texture at a stable
// index; a rect's flat vTexIdx selects it. NonUniformResourceIndex is
// REQUIRED: vTexIdx is per-vertex, so the index is non-uniform across the
// draw (noapi enables shader_sampled_image_array_non_uniform_indexing).
// samplers[0] = the shared linear/clamp sampler installed by the heap.
[[vk::binding(0, 0)]] Texture2D textures[];
[[vk::binding(0, 2)]] SamplerState samplers[];


// ── Marching-squares SDF coverage (the 5-tap fill) ──────────────────────
// The pixel's coverage reconstructed from 5 signed-distance samples (the
// center + the 4 edge midpoints): each of the 4 triangles (center + two
// adjacent edge midpoints) resolves its marching-squares case from the
// corner signs, the boundary crossings interpolate linearly in the signed
// distance, && the covered polygon's area is summed. The triangles cover
// half the pixel, so the coverage is the sum / 0.5.
float cross2(float2 u, float2 v) {
    return u.x * v.y - u.y * v.x;
}

/// The stroke's band signed distance at a point: the min distance to the
/// curves minus the band's outer AA edge (half + STROKE_AA) — negative
/// inside the stroke, positive beyond.
float strokeDist(float2 p, uint64_t curve_bda) {
    vk::BufferPointer<CurveBuf> cb = vk::BufferPointer<CurveBuf>(curve_bda);
    uint n = cb.Get().num_curves;
    float dmin = 1e9;
    for (uint i = 0u; i < n; i++) {
        QuadCurve cv = curveAt(curve_bda, i);
        dmin = min(dmin, distQuad(p, cv.p0, cv.p1, cv.p2));
    }
    return dmin;
}

float sdfStroke(float2 p, uint64_t curve_bda, float half) {
    return strokeDist(p, curve_bda) - half;
}

/// The classic 4-corner marching squares over the 1x1 pixel: the covered
/// area (== the coverage, the pixel's area is 1) from the SDFs at the 4
/// corners. The boundary crossings interpolate linearly in the signed
/// distance. The 16 cases collapse to: 0/4 in -> 0/1; 1 in -> the corner
/// triangle; 2 adjacent -> the quad; 2 opposite -> the two triangles (the
/// saddle, both halves); 3 in -> 1 minus the outside corner's triangle.
float msQuad(float stl, float str_, float sbr, float sbl) {
    const float2 TL = float2(0.0, 0.0);
    const float2 TR = float2(1.0, 0.0);
    const float2 BR = float2(1.0, 1.0);
    const float2 BL = float2(0.0, 1.0);
    uint n = ((stl < 0.0) ? 1u : 0u) + ((str_ < 0.0) ? 1u : 0u) + ((sbr < 0.0) ? 1u : 0u) + ((sbl < 0.0) ? 1u : 0u);
    if (n == 0u) return 0.0;
    if (n == 4u) return 1.0;
    // The edge crossings (linear in the signed distance):
    float2 x_top = TL + (stl / (stl - str_)) * (TR - TL);
    float2 x_right = TR + (str_ / (str_ - sbr)) * (BR - TR);
    float2 x_bottom = BR + (sbr / (sbr - sbl)) * (BL - BR);
    float2 x_left = BL + (sbl / (sbl - stl)) * (TL - BL);
    // The shoelace of a polygon given in order:
    // (the crossings are only used on the edges where the sign flips)
    if (n == 1u) {
        if (stl < 0.0) return 0.5 * abs(cross2(x_top - TL, x_left - TL));
        if (str_ < 0.0) return 0.5 * abs(cross2(TR - x_right, x_top - x_right));
        if (sbr < 0.0) return 0.5 * abs(cross2(BR - x_bottom, x_right - x_bottom));
        return 0.5 * abs(cross2(BL - x_left, x_bottom - x_left));
    }
    if (n == 3u) {
        // 1 minus the outside corner's triangle:
        if (stl >= 0.0) return 1.0 - 0.5 * abs(cross2(x_top - TL, x_left - TL));
        if (str_ >= 0.0) return 1.0 - 0.5 * abs(cross2(TR - x_right, x_top - x_right));
        if (sbr >= 0.0) return 1.0 - 0.5 * abs(cross2(BR - x_bottom, x_right - x_bottom));
        return 1.0 - 0.5 * abs(cross2(BL - x_left, x_bottom - x_left));
    }
    // Two inside:
    if (stl < 0.0 && str_ < 0.0) // the top edge in: the quad TL,TR,x_right,x_left
        return 0.5 * abs(cross2(TL, TR) + cross2(TR, x_right) + cross2(x_right, x_left) + cross2(x_left, TL));
    if (str_ < 0.0 && sbr < 0.0) // the right edge in
        return 0.5 * abs(cross2(TR, BR) + cross2(BR, x_bottom) + cross2(x_bottom, x_top) + cross2(x_top, TR));
    if (sbr < 0.0 && sbl < 0.0) // the bottom edge in
        return 0.5 * abs(cross2(BR, BL) + cross2(BL, x_left) + cross2(x_left, x_right) + cross2(x_right, BR));
    if (sbl < 0.0 && stl < 0.0) // the left edge in
        return 0.5 * abs(cross2(BL, TL) + cross2(TL, x_top) + cross2(x_top, x_bottom) + cross2(x_bottom, BL));
    // The saddle: the opposite corners in — the two triangles:
    if (stl < 0.0 && sbr < 0.0)
        return 0.5 * abs(cross2(x_top - TL, x_left - TL)) + 0.5 * abs(cross2(BR - x_bottom, x_right - x_bottom));
    return 0.5 * abs(cross2(TR - x_right, x_top - x_right)) + 0.5 * abs(cross2(BL - x_left, x_bottom - x_left));
}

/// The spec'd MARCHING QUADS coverage (algo 2): the exact covered area of
/// the stroke band within the quad of half-extent H = 0.5 + o, from the
/// signed band distance sampled at the center + 4 corners, resolved via
/// the 4 triangle marching squares. Clean reference implementation.
float marchingQuadsCoverage(float2 cell, uint64_t bda, float half, float o) {
    float2 pc = cell + 0.5;
    float sc = sdfStroke(pc, bda, half);
    if (sc > 2.0) return 0.0;   // fully outside
    if (sc < -2.0) return 1.0;  // fully inside
    float H = 0.5 + o;
    float2 tl = cell + float2(0.5 - H, 0.5 - H);
    float2 tr = cell + float2(0.5 + H, 0.5 - H);
    float2 br = cell + float2(0.5 + H, 0.5 + H);
    float2 bl = cell + float2(0.5 - H, 0.5 + H);
    float sd_tl = sdfStroke(tl, bda, half);
    float sd_tr = sdfStroke(tr, bda, half);
    float sd_br = sdfStroke(br, bda, half);
    float sd_bl = sdfStroke(bl, bda, half);
    // msTri uses the positive-inside convention; the band sd is negative
    // inside, so negate. The 4 triangles tile the quad.
    float area = msTri(pc, tl, tr, -sc, -sd_tl, -sd_tr) +
                 msTri(pc, tr, br, -sc, -sd_tr, -sd_br) +
                 msTri(pc, br, bl, -sc, -sd_br, -sd_bl) +
                 msTri(pc, bl, tl, -sc, -sd_bl, -sd_tl);
    float quad_area = (2.0 * H) * (2.0 * H);
    return clamp(area / quad_area, 0.0, 1.0);
}


/// `a`,`b`), from the signed distances at its corners: the covered area.
float msTri(float2 c, float2 a, float2 b, float sc, float sa, float sb) {
    // The triangle's full area from its legs (0.125 for the 1x1 quad's
    // half-legs, 0.5 for the 2x2's full legs) — the size is a parameter
    // of the tap positions, not a constant.
    const float FULL = 0.5 * abs(cross2(a - c, b - c));
    uint n = ((sc > 0.0) ? 1u : 0u) + ((sa > 0.0) ? 1u : 0u) + ((sb > 0.0) ? 1u : 0u);
    if (n == 0u) return 0.0;
    if (n == 3u) return FULL;
    // The boundary crossings, linear in the signed distance:
    float2 x_ca = c + (sc / (sc - sa)) * (a - c);
    float2 x_cb = c + (sc / (sc - sb)) * (b - c);
    float2 x_ab = a + (sa / (sa - sb)) * (b - a);
    if (n == 1u) {
        if (sc > 0.0) return 0.5 * abs(cross2(x_ca - c, x_cb - c));
        if (sa > 0.0) return 0.5 * abs(cross2(a - x_ca, x_ab - x_ca));
        return 0.5 * abs(cross2(x_ab - b, x_cb - b));
    }
    // Two inside: the covered quad, vertices ordered around the boundary.
    if (sc <= 0.0) return 0.5 * abs(cross2(a, b) + cross2(b, x_cb) + cross2(x_cb, x_ca) + cross2(x_ca, a));
    if (sa <= 0.0) return 0.5 * abs(cross2(c, b) + cross2(b, x_ab) + cross2(x_ab, x_ca) + cross2(x_ca, c));
    return 0.5 * abs(cross2(c, a) + cross2(a, x_ab) + cross2(x_ab, x_cb) + cross2(x_cb, c));
}

/// The mode-2 per-edge accumulation (the Cairo running-cover model): the
/// edge's signed height across a device pixel's logical window
/// [px, px+pixelSize.x) x [py, py+pixelSize.y), split across columns by
/// the fraction of its x-span. Banded and full loops use the same path.
/// Edges outside the y-window contribute exactly zero.
void accumulateStrokeEdge(
    Edge e,
    float px,
    float py,
    float2 pixelSize,
    inout float cover,
    inout float h_here,
    inout float u_here)
{
    float ay = e.p0.y;
    float by = e.p1.y;
    float ymin = min(ay, by);
    float ymax = max(ay, by);
    if (ymax <= py || ymin >= py + pixelSize.y) return;
    float yt = max(ymin, py);
    float yb = min(ymax, py + pixelSize.y);
    float inv = (by == ay) ? 0.0 : 1.0 / (by - ay);
    float xt = e.p0.x + (e.p1.x - e.p0.x) * (yt - ay) * inv;
    float xb = e.p0.x + (e.p1.x - e.p0.x) * (yb - ay) * inv;
    float sign = (by > ay) ? 1.0 : -1.0;
    float h = yb - yt;
    if (h <= 0.0) return;  // horizontal: carries no height
    float xlo = min(xt, xb);
    float xhi = max(xt, xb);
    float span = xhi - xlo;
    if (span <= 0.0) {
        // Vertical edge: the whole height belongs to the column at its x.
        if (xt < px) {
            cover += sign * h;
        } else if (xt < px + pixelSize.x) {
            h_here += sign * h;
            u_here += sign * (xt - px) * h;
        }
        return;
    }
    if (xhi <= px) { cover += sign * h; return; }
    if (xlo >= px + pixelSize.x) return;
    // The part of the edge's x-span inside this column:
    float hc = h * (min(xhi, px + pixelSize.x) - max(xlo, px)) / span;
    if (xlo < px) cover += sign * h * (px - xlo) / span;
    h_here += sign * hc;
    // The uncovered trapezoid: the area between the column's left and the
    // edge over the clipped y-extent.
    float xtc = clamp(xt, px, px + pixelSize.x);
    float xbc = clamp(xb, px, px + pixelSize.x);
    u_here += sign * 0.5 * ((xtc - px) + (xbc - px)) * hc;
}

// The logical pixel extent along the nearest rounded-box edge. For a
// corner, use the radial SDF normal; straight edges use their own axis.
float roundedEdgePixel(float2 q, float2 pixelSize) {
    float2 corner = max(q, float2(0.0));
    if (corner.x == 0.0 && corner.y == 0.0)
        return (q.x > q.y) ? pixelSize.x : pixelSize.y;
    return length(corner * pixelSize) / length(corner);
}

float paintRadius(float2 point, float2 size, float4 radius) {
    float scale = min(1.0, min(
        min(size.x / max(radius.x + radius.y, 1e-5),
            size.x / max(radius.w + radius.z, 1e-5)),
        min(size.y / max(radius.x + radius.w, 1e-5),
            size.y / max(radius.y + radius.z, 1e-5))));
    float4 r = radius * scale;
    if (point.y < size.y * 0.5) {
        return point.x < size.x * 0.5 ? r.x : r.y;
    }
    return point.x < size.x * 0.5 ? r.w : r.z;
}

float paintDistance(float2 point, float2 size, float4 radii) {
    float radius = paintRadius(point, size, radii);
    return sdRoundBox(point - size * 0.5, size * 0.5 - radius, radius);
}

float paintInnerDistance(float2 point, PaintExtra extra) {
    float4 borders = extra.border_width;
    float2 size = extra.size.xy - float2(borders.w + borders.y, borders.x + borders.z);
    if (size.x <= 0.0 || size.y <= 0.0) return 1e8;
    float4 radii = max(extra.radii - float4(
        max(borders.x, borders.w), max(borders.x, borders.y),
        max(borders.z, borders.y), max(borders.z, borders.w)), 0.0);
    return paintDistance(point - float2(borders.w, borders.x), size, radii);
}

float4 paintColor(PaintExtra extra, float2 point) {
    uint kind = extra.mode.x;
    if (kind == 3u) {
        float2 axis = extra.gradient.xy;
        float2 size = extra.size.xy;
        float span = max(abs(axis.x) * size.x + abs(axis.y) * size.y, 1e-5);
        float position = dot(point - size * 0.5, axis) / span + 0.5;
        float t = clamp((position - extra.gradient.z) /
            (extra.gradient.w - extra.gradient.z), 0.0, 1.0);
        return lerp(extra.from, extra.to, t);
    }
    if (kind == 4u || kind == 5u) {
        float2 cell = floor(point / extra.pattern.xy);
        float phase = kind == 4u ? cell.x + cell.y : cell.x;
        return (int(phase) & 1) == 0 ? extra.from : extra.to;
    }
    if (kind == 6u) {
        float2 uv = frac(point / extra.pattern.xy);
        float4 sample_color = textures[NonUniformResourceIndex(extra.mode.y)].Sample(samplers[0], uv);
        return float4(sample_color.rgb, sample_color.a * extra.from.a);
    }
    return extra.from;
}

int pathWinding(float2 point, uint64_t curve_bda) {
    CurveBuf buffer = vk::BufferPointer<CurveBuf>(curve_bda).Get();
    int winding = 0;
    for (uint i = 0u; i < buffer.num_curves; i++) {
        QuadCurve curve = curveAt(curve_bda, i);
        float a = curve.p0.y - 2.0 * curve.p1.y + curve.p2.y;
        float b = 2.0 * (curve.p1.y - curve.p0.y);
        float c = curve.p0.y - point.y;
        float2 roots = float2(-1.0, -1.0);
        uint count = 0u;
        if (abs(a) < 1e-6) {
            if (abs(b) < 1e-6) continue;
            roots.x = -c / b;
            count = 1u;
        } else {
            float discriminant = b * b - 4.0 * a * c;
            if (discriminant < 0.0) continue;
            float root = sqrt(discriminant);
            roots = float2((-b - root) / (2.0 * a), (-b + root) / (2.0 * a));
            count = root == 0.0 ? 1u : 2u;
        }
        for (uint j = 0u; j < count; j++) {
            float t = roots[j];
            if (t < 0.0 || t >= 1.0) continue;
            float x = (1.0 - t) * (1.0 - t) * curve.p0.x +
                2.0 * (1.0 - t) * t * curve.p1.x + t * t * curve.p2.x;
            if (x <= point.x) continue;
            float derivative = 2.0 * a * t + b;
            if (derivative > 0.0) winding++;
            else if (derivative < 0.0) winding--;
        }
    }
    return winding;
}

[shader("fragment")]
float4 main(
    [[vk::location(0)]] float2 vUv,
    [[vk::location(1)]] float4 vColor,
    [[vk::location(2)]] nointerpolation uint vMaterialIdx,
    [[vk::location(3)]] float2 vOrigin,
    [[vk::location(4)]] nointerpolation uint vTexIdx,
    [[vk::location(5)]] nointerpolation uint vClipId,
    [[vk::location(6)]] float2 vLocal,
    float4 fragPos : SV_Position)
{
    // Rasterization supplies SV_Position in physical framebuffer pixels.
    // Convert it once; clips, pens and material geometry are all logical.
    float2 logicalPos = fragPos.xy / pc.pixel_scale;
    if (vClipId != 0xFFFFFFFFu) {
        ClipRect c = vk::BufferPointer<ClipRect>(pc.indirect + 16 * uint64_t(vClipId)).Get();
        bool outsideX = c.w != -1.0 && (logicalPos.x < c.x || logicalPos.x >= c.x + c.w);
        bool outsideY = c.h != -1.0 && (logicalPos.y < c.y || logicalPos.y >= c.y + c.h);
        if (outsideX || outsideY) {
            discard;
        }
    }

    // TYPE_TEXTURE (P3): a bindless-sampled quad — checked BEFORE the
    // material dispatch, so a textured rect never touches its material.
    // vTexIdx ~0 = no texture (the test is a no-op — byte-identical to the
    // untextured draw). vUv is the normalized src UV the VS already
    // produces (texture rects use src = 0,0,1,1 → vUv spans the full
    // texture). vColor tints the sample (the CPU paints textured fills
    // white — the identity tint). samplers[0] = the shared linear/clamp
    // sampler.
    if (vTexIdx != 0xFFFFFFFFu) {
        float4 t = textures[NonUniformResourceIndex(vTexIdx)].Sample(samplers[0], vUv);
        return float4(t.rgb * vColor.rgb, t.a * vColor.a);
    }

    if (vMaterialIdx == 0u) { return vColor; }

    // writeMaterial stores glyph materials at their slot: the vertex's
    // material_idx indexes the material ARRAY at the buffer base (GLSL:
    // materials[mat_idx]; the 56-byte stride is GlyphMaterial's size).
    vk::BufferPointer<GlyphMaterial> mat = vk::BufferPointer<GlyphMaterial>(pc.vert_data + 56 * vMaterialIdx);
    GlyphMaterial m = mat.Get();

    if (m.type == TYPE_SOLID) { return vColor; }
    // One physical device pixel expressed in logical window units. Keep
    // material geometry and curve buffers unchanged across display scales.
    float2 pixelSize = float2(1.0, 1.0) / pc.pixel_scale;
    float2 halfPixel = 0.5 * pixelSize;
    if (m.type == TYPE_PATH_FILL) {
        PaintExtra extra = vk::BufferPointer<PaintExtra>(m.band_bda).Get();
        float2 footprint = fwidth(vLocal);
        float covered = 0.0;
        for (uint y = 0u; y < 4u; y++) {
            for (uint x = 0u; x < 4u; x++) {
                float2 sample_point = vLocal +
                    (float2(float(x), float(y)) * 0.25 - 0.375) * footprint;
                int winding = pathWinding(float2(sample_point.x, -sample_point.y), m.curve_bda);
                if (extra.mode.z == 0u ? winding != 0 : (winding & 1) != 0) covered += 1.0;
            }
        }
        float2 paint_point = float2(
            dot(extra.transform_x.xy, vLocal) + extra.transform_x.z,
            dot(extra.transform_y.xy, vLocal) + extra.transform_y.z);
        float4 color = paintColor(extra, paint_point);
        return float4(color.rgb, color.a * covered / 16.0);
    }

    if (m.type == TYPE_PAINT_RECT || m.type == TYPE_PAINT_SHADOW) {
        PaintExtra extra = vk::BufferPointer<PaintExtra>(m.curve_bda).Get();
        float2 point = vLocal - vOrigin;
        float2 size = extra.size.xy;
        float pixel = max(fwidth(vLocal.x), fwidth(vLocal.y));
        float outer = clamp(0.5 - paintDistance(point, size, extra.radii) / pixel, 0.0, 1.0);
        if (m.type == TYPE_PAINT_SHADOW) {
            float inset_clip = outer;
            if (extra.mode.z != 0u && any(extra.border_width > float4(0.0))) {
                inset_clip = clamp(
                    0.5 - paintInnerDistance(point, extra) / pixel, 0.0, 1.0);
            }
            float2 offset = extra.shadow.zw;
            float spread = extra.mode.z == 0u ? extra.shadow.y : -extra.shadow.y;
            float blur = max(extra.shadow.x, pixel);
            float2 shifted = point - offset + spread;
            float2 shadow_size = size + 2.0 * spread;
            if (shadow_size.x <= 0.0 || shadow_size.y <= 0.0) {
                return float4(vColor.rgb,
                    extra.mode.z == 0u ? 0.0 : vColor.a * inset_clip);
            }
            float4 shadow_radii = max(extra.radii + spread, 0.0);
            float distance = paintDistance(shifted, shadow_size, shadow_radii);
            float coverage = extra.mode.z == 0u
                ? clamp(0.5 - distance / blur, 0.0, 1.0)
                : inset_clip * clamp(0.5 + distance / blur, 0.0, 1.0);
            return float4(vColor.rgb, vColor.a * coverage);
        }
        float inner = clamp(0.5 - paintInnerDistance(point, extra) / pixel, 0.0, 1.0);
        if (extra.mode.x == 1u) {
            float border = clamp(outer - inner, 0.0, 1.0);
            float4 distance = float4(point.y, size.x - point.x, size.y - point.y, point.x);
            uint side = distance.x < distance.y ? 0u : 1u;
            side = distance[side] < distance.z ? side : 2u;
            side = distance[side] < distance.w ? side : 3u;
            if (extra.border_width[side] <= 0.0 || extra.border_styles[side] == 0u)
                discard;
            if (extra.border_styles[side] >= 2u) {
                float width = extra.border_width[side];
                float along = side == 0u || side == 2u ? point.x : point.y;
                float period = max(width * 4.0, pixel);
                float phase = frac(along / period) * period;
                if (extra.border_styles[side] == 2u) {
                    border *= clamp((period * 0.6 - phase) / pixel + 0.5, 0.0, 1.0);
                } else {
                    float center = width;
                    float normal = distance[side] - width * 0.5;
                    float radius = width * 0.5;
                    float dot_distance = length(float2(phase - center, normal));
                    border *= clamp((radius - dot_distance) / pixel + 0.5, 0.0, 1.0);
                }
            }
            float4 color = side == 0u ? extra.border_top :
                side == 1u ? extra.border_right :
                side == 2u ? extra.border_bottom : extra.border_left;
            return float4(color.rgb, color.a * border);
        }
        float4 color = paintColor(extra, point);
        float fill_coverage = any(extra.border_width > float4(0.0)) ? inner : outer;
        return float4(color.rgb, color.a * fill_coverage);
    }


    if (m.type == TYPE_GLYPH) {
        vk::BufferPointer<CurveBuf> cb = vk::BufferPointer<CurveBuf>(m.curve_bda);
        uint n = cb.Get().num_curves;

        // The glyph's pen and outline are logical coordinates, y-up.
        // Integrate the logical footprint of one physical pixel around
        // SV_Position's center; at 1x this is the original 1x1 window.
        float2 cell = float2(logicalPos.x - vOrigin.x - halfPixel.x,
                             vOrigin.y - logicalPos.y - halfPixel.y);
        float pixelArea = pixelSize.x * pixelSize.y;
        // QUAD DEBUG (frag_data bit 1): tint the whole quad's background —
        // the ink on top, so the quad bounds show against the glyph. The
        // color is the OKLAB of a bright sRGB magenta (0.70, 0.28, -0.17).
        if ((pc.frag_data & uint64_t(2)) != uint64_t(0)) {
            float cov = 0.0;
            for (uint i = 0u; i < n; i++) {
                QuadCurve cv = curveAt(m.curve_bda, i);
                cov += sweepSegment(pixelSize, cell, cv.p0, cv.p1, cv.p2);
            }
            cov = clamp(cov / pixelArea, 0.0, 1.0);
            return float4(lerp(float3(0.70, 0.28, -0.17), vColor.rgb, cov), 1.0);
        }
        // SUBPIXEL AA (frag_data bit 0): split the pixel into three 1/3-px
        // columns && sweep each (the display's RGB stripes in that
        // order: left = R, middle = G, right = B). The output chroma is
        // the barycentric mix of the three PRIMARIES' ab coordinates
        // weighted by the column coverages (Oklab primaries: R(0.2249,
        // 0.1258), G(-0.2339, 0.1795), B(-0.0325, -0.3115)); the
        // luminance is the mean coverage (l+m+r)/3, boosted by the
        // fragment's own average RGB over white so the text renders at
        // full brightness, && carried by the alpha for compositing.
        // OFF (frag_data = 0): the single analytic sweep, grayscale.
        if ((pc.frag_data & uint64_t(1)) != uint64_t(0)) {
            float cl = 0.0, cm = 0.0, cr = 0.0;
            float colStep = pixelSize.x / 3.0;
            float2 colSize = float2(colStep, pixelSize.y);
            for (uint i = 0u; i < n; i++) {
                QuadCurve cv = curveAt(m.curve_bda, i);
                cl += sweepSegment(colSize, cell, cv.p0, cv.p1, cv.p2);
                cm += sweepSegment(colSize, float2(cell.x + colStep, cell.y), cv.p0, cv.p1, cv.p2);
                cr += sweepSegment(colSize, float2(cell.x + 2.0 * colStep, cell.y), cv.p0, cv.p1, cv.p2);
            }
            cl = clamp(cl * 3.0 / pixelArea, 0.0, 1.0);
            cm = clamp(cm * 3.0 / pixelArea, 0.0, 1.0);
            cr = clamp(cr * 3.0 / pixelArea, 0.0, 1.0);
            float avg = (cl + cm + cr) / 3.0;
            // Physical LCD assembly (the reference shader's model): the
            // pixel's LINEAR RGB is the three subpixel coverages — the R
            // column's coverage is the R channel, etc. — modulated by the
            // TEXT color's linear RGB (the old code ignored vColor and
            // assumed white). The stripe order is panel-dependent and
            // often undeclared (BOE EDID: undefined) — bit 2 of frag_data
            // swaps to BGR for the empirical test.
            float3 sub = float3(cl, cm, cr);
            if ((pc.frag_data & uint64_t(4)) != uint64_t(0)) sub = float3(cr, cm, cl);
            float3 text_lin = oklabToSRGB(vColor.rgb);
            float3 lab = linearToOklab(sub * text_lin);
            // The assembled L already encodes the coverages, so normalize
            // it to the full ink BEFORE the alpha: the src-over blend
            // multiplies by avg again, && without this the edge pixels
            // double-darken.
            float L = clamp(lab.x / max(avg, 1e-3), 0.0, 1.0);
            // Chroma damping ≈ FreeType's 5-tap LCD filter in one line:
            // keep the luminance detail (the sharpness), kill the fringe
            // color (raw column coverages fringe maximally). Tune 0.2-0.5;
            // bit 3 of frag_data disables it (the full-chroma order test).
            if ((pc.frag_data & uint64_t(8)) != uint64_t(0)) lab.yz *= 0.3;
            return float4(L, lab.y, lab.z, avg * vColor.a);
        }

        // The text coverage is the swept area of one device pixel divided
        // by its logical area. The SVG fills use their own inflated sweep.
        float total = 0.0;
        for (uint i = 0u; i < n; i++) {
            QuadCurve cv = curveAt(m.curve_bda, i);
            total += sweepSegment(pixelSize, cell, cv.p0, cv.p1, cv.p2);
        }
        float coverage = clamp(abs(total) / pixelArea, 0.0, 1.0);
        return float4(vColor.rgb, coverage * vColor.a);
    }

    if (m.type == TYPE_SWEEP) {
        // Band rows were built for a 2x2 logical window. A larger device
        // footprint can overlap curves omitted from those fixed rows.
        float2 cell_f = float2(logicalPos.x - vOrigin.x - halfPixel.x,
                               vOrigin.y - logicalPos.y - halfPixel.y);
        vk::BufferPointer<CurveBuf> cb_f = vk::BufferPointer<CurveBuf>(m.curve_bda);
        uint nf = cb_f.Get().num_curves;
        float2 win_f = pixelSize * SWEEP_WINDOW;
        float2 off_f = cell_f + halfPixel - 0.5 * win_f;
        float winArea = win_f.x * win_f.y;
        // The fill-band fast path is safe when its fixed logical y-window
        // contains the device window. Otherwise use the complete curve set.
        if (m.band_bda != uint64_t(0) && pc.pixel_scale.y >= 1.0) {
            BandHeader bh = vk::BufferPointer<BandHeader>(m.band_bda).Get();
            // INTERIOR: the whole sweep window fits in the verified
            // interior box. No curve crosses it, so coverage is one.
            if (off_f.x >= bh.interior_rect.x && off_f.y >= bh.interior_rect.y &&
                off_f.x + win_f.x <= bh.interior_rect.x + bh.interior_rect.z &&
                off_f.y + win_f.y <= bh.interior_rect.y + bh.interior_rect.w) {
                return float4(vColor.rgb, vColor.a);
            }
            // BAND: this fragment's pixel row's curve run.
            int row = int(floor(cell_f.y)) - bh.row_base;
            if (row >= 0 && row < int(bh.row_count)) {
                uint pair_off = bh.pairs_base + 2u * uint(row);
                uint64_t pair_addr = m.band_bda + uint64_t(4) * uint64_t(pair_off);
                uint idx_off = vk::BufferPointer<uint>(pair_addr).Get();
                uint count = vk::BufferPointer<uint>(pair_addr + uint64_t(4)).Get();
                float total_f = 0.0;
                for (uint i = 0u; i < count; i++) {
                    uint ci = vk::BufferPointer<uint>(m.band_bda + uint64_t(4) * uint64_t(bh.indices_base + idx_off + i)).Get();
                    QuadCurve cv = curveAt(m.curve_bda, ci);
                    total_f += sweepSegment(win_f, off_f, cv.p0, cv.p1, cv.p2);
                }
                // ZERO-COVERAGE DISCARD: the run summed to exactly 0.0
                // (a fragment whose window misses every curve in the row —
                // e.g. a column outside the path's x-extent). The coverage
                // is then clamp(0/4) == 0, pow(0, 1/GAMMA) == 0, alpha 0 —
                // the blend would leave the dst untouched, so discard is
                // pixel-identical and saves the ROP write.
                if (total_f == 0.0) discard;
                float cov_f = clamp(abs(total_f) / winArea, 0.0, 1.0);
                cov_f = pow(cov_f, 1.0 / COVERAGE_GAMMA);
                return float4(vColor.rgb, cov_f * vColor.a);
            }
            // The row is outside the band (e.g. the rect's 2px AA
            // surround): the band's row range is the union over the
            // curves' sweep-window overlaps — the same endpoint extremes
            // (min/max of p0.y, p2.y) as sweepSegment's first-line y-clip,
            // so a row outside it has EVERY curve's y-clip firing (max(p0.y,
            // p2.y) <= off.y above, min(p0.y, p2.y) >= off.y + size.y
            // below) and every sweepSegment returns exactly 0.0 — the full
            // loop's sum is exactly 0.0, bit-identical. Return the
            // coverage-0 result directly; the full loop only runs when the
            // band data is absent (band_bda == 0, kept above).
            return float4(vColor.rgb, 0.0);
        }
        float total_f = 0.0;
        for (uint i = 0u; i < nf; i++) {
            QuadCurve cv = curveAt(m.curve_bda, i);
            total_f += sweepSegment(win_f, off_f, cv.p0, cv.p1, cv.p2);
        }
        // ZERO-COVERAGE DISCARD (the no-band fallback): identical to the
        // banded path — total 0.0 → cov 0 → alpha 0, so discard is
        // pixel-identical and skips the ROP write.
        if (total_f == 0.0) discard;
        float cov_f = clamp(abs(total_f) / winArea, 0.0, 1.0);
        cov_f = pow(cov_f, 1.0 / COVERAGE_GAMMA);
        return float4(vColor.rgb, cov_f * vColor.a);
    }

    if (m.type == TYPE_STROKE || m.type == TYPE_PATH_STROKE) {
        // Curves and stroke width are in logical units. Pixel sampling
        // uses the physical pixel's logical footprint.
        float2 cell_s = float2(logicalPos.x - vOrigin.x - halfPixel.x,
                               vOrigin.y - logicalPos.y - halfPixel.y);
        float edgePixel = max(pixelSize.x, pixelSize.y);
        float half = max(m.bearing_y * 0.5, 0.25 * edgePixel);
        float2 c_s = cell_s + halfPixel;
        uint algo = uint(m.win_w + 0.5); // 0, 1 or 2
        float o = m.win_h * edgePixel; // oversize measured in physical pixels

        if (algo == 0u) {
            // NAIVE SDF: the exact distance at the pixel center + the
            // smoothstep band over the oversize.
            float d = strokeDist(c_s, m.curve_bda);
            float cov = 1.0 - smoothstep(half - o, half + o, d);
            cov = pow(cov, 1.0 / COVERAGE_GAMMA);
            return float4(vColor.rgb, cov * vColor.a);
        }

        if (algo == 2u) {
            // The Cairo reference integrates each device pixel through
            // the offset-outline edges. cover and h_here accumulate
            // logical heights; u_here is a logical area. Normalize by
            // the pixel's logical width and height for alpha coverage.
            vk::BufferPointer<EdgeBuf> eb = vk::BufferPointer<EdgeBuf>(m.curve_bda);
            uint ne = eb.Get().count;
            // Fixed 1-unit y-windows contain device-pixel windows only
            // when the y scale is at least one. Below that, sweep all edges.
            float px = c_s.x - halfPixel.x;
            float py = c_s.y - halfPixel.y;
            if (m.band_bda != uint64_t(0) && pc.pixel_scale.y >= 1.0) {
                BandHeader bh = vk::BufferPointer<BandHeader>(m.band_bda).Get();
                int row = int(floor(py)) - bh.row_base;
                if (row >= 0 && row < int(bh.row_count)) {
                    uint pair_off = bh.pairs_base + 2u * uint(row);
                    uint64_t pair_addr = m.band_bda + uint64_t(4) * uint64_t(pair_off);
                    uint idx_off = vk::BufferPointer<uint>(pair_addr).Get();
                    uint count = vk::BufferPointer<uint>(pair_addr + uint64_t(4)).Get();
                    float cover = 0.0;   // running covered height (columns < px)
                    float h_here = 0.0;  // covered height in this column
                    float u_here = 0.0;  // uncovered trapezoid area in this column
                    for (uint i = 0u; i < count; i++) {
                        uint ei = vk::BufferPointer<uint>(m.band_bda + uint64_t(4) * uint64_t(bh.indices_base + idx_off + i)).Get();
                        accumulateStrokeEdge(edgeAt(m.curve_bda, ei), px, py, pixelSize, cover, h_here, u_here);
                    }
                    // ZERO-COVERAGE DISCARD: the accumulated total is
                    // exactly 0.0 (every edge in the run fails the y-clip
                    // for this fragment) → cov == 0 → alpha 0 — the blend
                    // would leave the dst untouched, so discard is
                    // pixel-identical and saves the ROP write.
                    float c = cover + h_here - u_here / pixelSize.x;
                    if (c == 0.0) discard;
                    // |.| takes the winding magnitude: the accumulated
                    // value is the SIGNED covered area (negative for
                    // CW-wound bands, e.g. horizontal strokes whose caps
                    // run against the row), and the coverage is its
                    // magnitude. With the running cover in place the abs
                    // no longer complements right edges — it only flips
                    // the whole-band sign.
                    float cov = clamp(abs(c) / pixelSize.y, 0.0, 1.0);
                    cov = pow(cov, 1.0 / COVERAGE_GAMMA);
                    return float4(vColor.rgb, cov * vColor.a);
                }
                // The row is outside the band (e.g. the rect's 2px AA
                // surround): the band's row range is the union over the
                // edges' window overlaps — a row outside it has EVERY edge
                // failing the y-clip (ymax <= py or ymin >= py + pixelSize.y
                // below) → accumulateStrokeEdge returns before any
                // accumulation → the total is exactly 0.0, bit-identical
                // to the full loop. Return the coverage-0 result directly;
                // the full loop only runs when the band data is absent
                // (band_bda == 0, kept above).
                return float4(vColor.rgb, 0.0);
            }
            float cover = 0.0;   // running covered height (columns < px)
            float h_here = 0.0;  // covered height in this column
            float u_here = 0.0;  // uncovered trapezoid area in this column
            for (uint i = 0u; i < ne; i++) {
                accumulateStrokeEdge(edgeAt(m.curve_bda, i), px, py, pixelSize, cover, h_here, u_here);
            }
            // ZERO-COVERAGE DISCARD (the no-band fallback): identical to
            // the banded path — total 0.0 → cov 0 → alpha 0, so discard is
            // pixel-identical and skips the ROP write.
            float c = cover + h_here - u_here / pixelSize.x;
            if (c == 0.0) discard;
            // |.| takes the winding magnitude: the accumulated value is
            // the SIGNED covered area (negative for CW-wound bands, e.g.
            // horizontal strokes whose caps run against the row), and the
            // coverage is its magnitude. With the running cover in place
            // the abs no longer complements right edges — it only flips
            // the whole-band sign.
            float cov = clamp(abs(c) / pixelSize.y, 0.0, 1.0);
            cov = pow(cov, 1.0 / COVERAGE_GAMMA);
            return float4(vColor.rgb, cov * vColor.a);
        }

        // MARCHING QUADS (algo 1): sample the center and four corners of
        // a device-pixel-scale quad, then integrate the four triangles.
        float2 hq = (0.5 + m.win_h) * pixelSize;
        float cutoff = (pc.pixel_scale.x == 1.0 && pc.pixel_scale.y == 1.0)
            ? 2.0 : max(2.0 * edgePixel, length(hq));
        float sd_c = sdfStroke(c_s, m.curve_bda, half);
        if (sd_c > cutoff) return float4(vColor.rgb, 0.0);
        if (sd_c < -cutoff) return float4(vColor.rgb, vColor.a);
        float2 tl = cell_s + float2(halfPixel.x - hq.x, halfPixel.y - hq.y);
        float2 tr = cell_s + float2(halfPixel.x + hq.x, halfPixel.y - hq.y);
        float2 br = cell_s + float2(halfPixel.x + hq.x, halfPixel.y + hq.y);
        float2 bl = cell_s + float2(halfPixel.x - hq.x, halfPixel.y + hq.y);
        float sd_tl = sdfStroke(tl, m.curve_bda, half);
        float sd_tr = sdfStroke(tr, m.curve_bda, half);
        float sd_br = sdfStroke(br, m.curve_bda, half);
        float sd_bl = sdfStroke(bl, m.curve_bda, half);
        // msTri expects the positive-inside convention; the stroke's sd is
        // negative inside, so negate.
        float area = msTri(c_s, tl, tr, -sd_c, -sd_tl, -sd_tr) +
                     msTri(c_s, tr, br, -sd_c, -sd_tr, -sd_br) +
                     msTri(c_s, br, bl, -sd_c, -sd_br, -sd_bl) +
                     msTri(c_s, bl, tl, -sd_c, -sd_bl, -sd_tl);
        float quad_area = (2.0 * hq.x) * (2.0 * hq.y);
        float cov = clamp(area / quad_area, 0.0, 1.0);
        cov = pow(cov, 1.0 / COVERAGE_GAMMA);
        return float4(vColor.rgb, cov * vColor.a);
    }

    if (m.type == TYPE_ROUNDED_RECT) {
        // Rounded-rect fill or ring. Material dimensions, radii, border
        // width and vOrigin stay in logical window coordinates.
        float2 size = float2(m.win_w, m.win_h);
        float2 radius = max(float2(m.curve_w, m.curve_h), float2(0.0));
        // Clamp radii to half the box so the SDF never inverts.
        radius = min(radius, size * 0.5);
        float2 p = logicalPos - vOrigin - size * 0.5;
        // Inigo Quilez sdRoundBox: one formula, no branches (sdRoundRect
        // keeps the GLSL's operation order: q = abs(p) - size*0.5 + radius).
        float d = sdRoundRect(p, size, radius);
        float outerPixel = max(pixelSize.x, pixelSize.y);
        if (pixelSize.x != pixelSize.y) {
            float2 q = abs(p) - size * 0.5 + radius;
            outerPixel = roundedEdgePixel(q, pixelSize);
        }
        float outer = clamp(0.5 - d / outerPixel, 0.0, 1.0);
        float coverage = outer;
        float border = m.bearing_y;
        if (border > 0.0 && border < min(size.x, size.y) * 0.5) {
            // Ring: subtract the inner rounded rect (box inset by the
            // border, corner radius reduced by the border) —
            // sdRoundRectInner keeps the GLSL's order verbatim.
            float id = sdRoundRectInner(p, size, radius, border);
            float innerPixel = max(pixelSize.x, pixelSize.y);
            if (pixelSize.x != pixelSize.y) {
                float2 innerRadius = max(radius - border, float2(0.0));
                float2 iq = abs(p) - (size * 0.5 - border) + innerRadius;
                innerPixel = roundedEdgePixel(iq, pixelSize);
            }
            float inner = clamp(0.5 - id / innerPixel, 0.0, 1.0);
            coverage = clamp(outer - inner, 0.0, 1.0);
        }
        // Vertical gradient: gradient_to.w > 0 enables the mix. vUv.y = 0
        // at the top, 1 at the bottom; vColor.rgb is the gradient top.
        float3 rgb = vColor.rgb;
        if (m.gradient_to.w > 0.0) {
            rgb = lerp(vColor.rgb, m.gradient_to.rgb, clamp(vUv.y, 0.0, 1.0));
        }
        return float4(rgb, coverage * vColor.a);
    }

    if (m.type == TYPE_SHADOW) {
        // Feathered rounded-rect shadow. win_w/win_h = the shadow rect size,
        // curve_w/curve_h = the widget's corner radii, bearing_y = the
        // feather (logical soft-edge width). Same SDF shape as ROUNDED_RECT,
        // but its fade spans the feather rather than a device pixel.
        // There is no ring subtraction. sdShadowRect retains the GLSL
        // order: hbox = size*0.5 - radius, then q = abs(p) - hbox.
        float2 size = float2(m.win_w, m.win_h);
        float2 radius = max(float2(m.curve_w, m.curve_h), float2(0.0));
        radius = min(radius, size * 0.5);
        float2 p = logicalPos - vOrigin - size * 0.5;
        // Canonical sdRoundBox (the same formula ROUNDED_RECT uses): the
        // inside term min(max(q.x,q.y), 0.0) makes the interior distance
        // the true edge distance. Without it the inside distance is just
        // -r, so zero/thin-radius shadows (r < feather/2) render at
        // 0.5 + r/feather partial opacity instead of saturating.
        float d = sdShadowRect(p, size, radius);
        float feather = max(m.bearing_y, 0.5 * max(pixelSize.x, pixelSize.y));
        float coverage = clamp(0.5 - d / feather, 0.0, 1.0);
        return float4(vColor.rgb, coverage * vColor.a);
    }
    return vColor;
}
