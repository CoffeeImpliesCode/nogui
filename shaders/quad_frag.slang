// quad_frag.slang — BIT-EXACT Slang port of shaders/quad_frag.glsl.
// Same float operation order, same literals, no reformulation, no fused
// ops. The only changes are the mechanical GLSL → Slang translations
// (vecN → floatN, mix → lerp, gl_FragCoord → fragPos, buffer_reference →
// vk::BufferPointer<T>.Get(), push_constant uniform → global
// [[vk::push_constant]] variable).
//
// Entry: main (fragment) — the runtime loads the .spv with entry "main".
// Vertex interface (locations in GLSL order): vUv@0, vColor@1,
// vMaterialIdx@2 (flat), vOrigin@3, vTexIdx@4 (flat, NEW — the bindless
// texture heap index; ~0 = none, P3), vClipId@5 (flat, NEW — the clip-rect
// index; ~0 = none); SV_Position carries gl_FragCoord.
// Push constant ABI: PushData { uint64_t vert_data @0; uint64_t frag_data
// @8; uint64_t indirect @16 (clip-rect buffer BDA) } — the toggle bits are
// read from the SECOND field (GLSL pc.vp_h_packed → frag_data here; the
// ABI is the offset, not the name).
//
// GLSL source line mapping (shaders/quad_frag.glsl):
//   in/out interface .............. 5-10
//   TYPE_* constants ............... 12-15
//   GlyphMaterial struct ........... 17-26
//   QuadCurve / CurveBuf structs ... 32-42
//   push constant .................. 163-166
//   sweepIntersect/sweepEval/sweepSegment ... 54-132 → lib/coverage.slang
//   linearToOklab/oklabToSRGB ...... 192-217 → lib/color.slang
//   main() ......................... 269-433
//     early-out vMaterialIdx==0 .... 270
//     material fetch (materials[mat_idx] → direct .Get(); the CPU writes
//       each glyph's material at its slot, so vert_data points straight
//       at it) ..................... 272-274
//     TYPE_SOLID ................... 276
//     TYPE_GLYPH ................... 278-363
//       curve buf + num_curves ..... 279-280
//       cell math .................. 293-294
//       quad-debug tint (bit 1) .... 298-307
//       subpixel AA (bit 0) ........ 318-353
//       grayscale sweep ............ 355-362
//     TYPE_ROUNDED_RECT ............ 365-408
//       outer SDF .................. 383-387 → sdRoundRect
//       ring subtraction ........... 389-399 → sdRoundRectInner
//       vertical gradient .......... 402-405
//     TYPE_SHADOW .................. 410-431 → sdShadowRect
//     fallthrough .................. 432
//
// Not ported (dead in the GLSL — no call sites in main): ByteBuf (44-46),
// texelCoverage (135-141), sampleCoverage (147-161), && the scanline
// sweeper intersectMonotonic/evalBez/scanlineSweep (169-267; it lives in
// lib/coverage for the compute path). dFdx/ddy are absent from the GLSL
// (the sweep windows are fixed-size), so nothing to port there.

import lib.color;
import lib.coord;
import lib.coverage;

static const int TYPE_SOLID = 0;
static const int TYPE_GLYPH = 1;
static const int TYPE_ROUNDED_RECT = 2;
static const int TYPE_SHADOW = 3;
static const int TYPE_STROKE = 4;
static const int TYPE_SWEEP = 5; // the SVG fill: the SDF AA, no subpixel

// The coverage gamma (Blinn's compositing practice): the alpha is NOT the
// literal sub-pixel area — pow(cov, 1/GAMMA) raises the low coverages so
// sub-pixel features (the tiger's 0.02-1px strokes) read as ink instead
// of faint gray, while the wide shapes (cov = 1) are untouched. 1.6 is
// the lighter end of the usual 1.6-2.2 range.
static const float COVERAGE_GAMMA = 1.6;

// The stroke's AA band width in fwidth units: the transition spans
// half ± STROKE_AA*fwidth (2*fwidth total at 1.0). Wider = softer edges.
static const float STROKE_AA = 1.5;
// The SVG fill's sweep window in px (1.0 = the exact 1x1 pixel). Inflating
// it box-filters the coverage over the neighborhood, smoothing the fill
// boundaries (an experiment knob — the boundary blur grows with the size).
static const float SWEEP_WINDOW = 2.0;

// GLSL GlyphMaterial (std430 buffer_reference layout, 48 bytes):
// int type @0; float bearing_y/curve_w/curve_h/win_w/win_h @4..24;
// uint64_t curve_bda @24; float4 gradient_to @32.
struct GlyphMaterial {
    int type;
    float bearing_y;
    float curve_w;
    float curve_h;
    float win_w;
    float win_h;
    uint64_t curve_bda;
    float4 gradient_to; // gradient bottom color (Oklab); .w > 0 enables the gradient
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

// Push constant. Field order/offsets match the CPU writes: vert_data @0,
// frag_data @8, indirect @16 (the clip-rect buffer BDA). The GLSL names
// were material_buf_bda / vp_h_packed; the ABI is the offset, so the port
// keeps vert_data/frag_data/indirect.
struct PushData {
    uint64_t vert_data;
    uint64_t frag_data;
    uint64_t indirect;
};

// Clip rect (framebuffer px), 16 bytes — the CPU writes these verbatim
// into the host-visible clip buffer; pc.indirect + 16 * clip_id indexes
// them. 0xFFFFFFFF (vClipId) = no clip: the test is a no-op.
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

[shader("fragment")]
float4 main(
    [[vk::location(0)]] float2 vUv,
    [[vk::location(1)]] float4 vColor,
    [[vk::location(2)]] nointerpolation uint vMaterialIdx,
    [[vk::location(3)]] float2 vOrigin,
    [[vk::location(4)]] nointerpolation uint vTexIdx,
    [[vk::location(5)]] nointerpolation uint vClipId,
    float4 fragPos : SV_Position)
{
    // Clip test FIRST (before the material fetch, so even the solid
    // early-out below respects it): a non-~0 vClipId selects a clip rect
    // from the BDA buffer; fragments outside are discarded. With vClipId
    // ~0 the test is a no-op — byte-identical to the unclipped draw.
    if (vClipId != 0xFFFFFFFFu) {
        ClipRect c = vk::BufferPointer<ClipRect>(pc.indirect + 16 * uint64_t(vClipId)).Get();
        if (fragPos.x < c.x || fragPos.y < c.y || fragPos.x > c.x + c.w || fragPos.y > c.y + c.h) {
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
    // materials[mat_idx]; the 48-byte stride is GlyphMaterial's size).
    vk::BufferPointer<GlyphMaterial> mat = vk::BufferPointer<GlyphMaterial>(pc.vert_data + 48 * vMaterialIdx);
    GlyphMaterial m = mat.Get();

    if (m.type == TYPE_SOLID) { return vColor; }

    if (m.type == TYPE_GLYPH) {
        vk::BufferPointer<CurveBuf> cb = vk::BufferPointer<CurveBuf>(m.curve_bda);
        uint n = cb.Get().num_curves;

        // The pixel's TRUE span, anchored at the GLYPH'S PEN: gl_FragCoord
        // is the fragment CENTER, so the pixel at the pen-relative offset
        // (dx, dy) covers [cell.x, cell.x+1) x [cell.y, cell.y+1) in the
        // OUTLINE's coordinate space. The outline curves are y-UP with
        // the origin at the pen, so cell.y is the pixel's y-up distance
        // from the pen (vOrigin.y); the -0.5 anchors the window at the
        // pixel's bottom-left. (The old cell was anchored at the QUAD's
        // top-left but the curves are pen-relative — every window sat
        // 2px up-left of its pixel, extruding the ink's top/left edges
        // && cutting its bottom/right by the same amount. vOrigin for
        // TYPE_GLYPH is the pen, so the two are the same space now.)
        float2 cell = float2(fragPos.x - vOrigin.x - 0.5,
                             vOrigin.y - fragPos.y - 0.5);
        // QUAD DEBUG (frag_data bit 1): tint the whole quad's background —
        // the ink on top, so the quad bounds show against the glyph. The
        // color is the OKLAB of a bright sRGB magenta (0.70, 0.28, -0.17).
        if ((pc.frag_data & uint64_t(2)) != uint64_t(0)) {
            float cov = 0.0;
            for (uint i = 0u; i < n; i++) {
                QuadCurve cv = curveAt(m.curve_bda, i);
                cov += sweepSegment(float2(1.0), cell, cv.p0, cv.p1, cv.p2);
            }
            cov = clamp(cov, 0.0, 1.0);
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
            for (uint i = 0u; i < n; i++) {
                QuadCurve cv = curveAt(m.curve_bda, i);
                cl += sweepSegment(float2(1.0 / 3.0, 1.0), float2(cell.x + 0.0 / 3.0, cell.y), cv.p0, cv.p1, cv.p2);
                cm += sweepSegment(float2(1.0 / 3.0, 1.0), float2(cell.x + 1.0 / 3.0, cell.y), cv.p0, cv.p1, cv.p2);
                cr += sweepSegment(float2(1.0 / 3.0, 1.0), float2(cell.x + 2.0 / 3.0, cell.y), cv.p0, cv.p1, cv.p2);
            }
            cl = clamp(cl * 3.0, 0.0, 1.0); // sweepSegment returns the filled AREA;
            cm = clamp(cm * 3.0, 0.0, 1.0); // over a 1/3-wide column that is 1/3 of
            cr = clamp(cr * 3.0, 0.0, 1.0); // the fraction — rescale to coverage.
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

        // The TEXT coverage: the exact analytic sweep (the signed area of
        // the path over the 1x1 pixel window) — |total| for the winding.
        // This is the glyphs' AA: exact, sharp, && the subpixel branch
        // above applies only here. The SVG fills use TYPE_SWEEP (their
        // own branch below) so the text && the tiger stay independent.
        float total = 0.0;
        for (uint i = 0u; i < n; i++) {
            QuadCurve cv = curveAt(m.curve_bda, i);
            total += sweepSegment(float2(1.0), cell, cv.p0, cv.p1, cv.p2);
        }
        float coverage = clamp(abs(total), 0.0, 1.0);
        return float4(vColor.rgb, coverage * vColor.a);
    }

    if (m.type == TYPE_SWEEP) {
        // The SVG FILL: the ANALYTICAL COVERAGE — the sweep's exact area
        // integral over an inflated window (SWEEP_WINDOW x SWEEP_WINDOW,
        // the "2x fill rect"), gamma-corrected. No SDF, no marching
        // squares — the stroke owns that machinery.
        float2 cell_f = float2(fragPos.x - vOrigin.x - 0.5,
                               vOrigin.y - fragPos.y - 0.5);
        vk::BufferPointer<CurveBuf> cb_f = vk::BufferPointer<CurveBuf>(m.curve_bda);
        uint nf = cb_f.Get().num_curves;
        float2 win_f = float2(SWEEP_WINDOW, SWEEP_WINDOW);
        float2 off_f = cell_f + 0.5 - 0.5 * win_f; // centered on the pixel
        float total_f = 0.0;
        for (uint i = 0u; i < nf; i++) {
            QuadCurve cv = curveAt(m.curve_bda, i);
            total_f += sweepSegment(win_f, off_f, cv.p0, cv.p1, cv.p2);
        }
        float cov_f = clamp(abs(total_f) / (SWEEP_WINDOW * SWEEP_WINDOW), 0.0, 1.0);
        cov_f = pow(cov_f, 1.0 / COVERAGE_GAMMA);
        return float4(vColor.rgb, cov_f * vColor.a);
    }

    if (m.type == TYPE_STROKE) {
        // The stroke: distance to the curves, banded at the half-width
        // (bearing_y, in the scaled pixel space like the curves). The
        // cell is bbox-relative y-up, identical to the fill's sweep. The
        // per-tap distances come from sdfStroke (the marching-squares
        // taps), which fetches the curve buffer itself.
        float2 cell_s = float2(fragPos.x - vOrigin.x - 0.5,
                               vOrigin.y - fragPos.y - 0.5);
        // TEMPORARY: clamp the stroke width to 0.5px from below.
        float half = max(m.bearing_y * 0.5, 0.25);
        float2 c_s = cell_s + 0.5;
        uint algo = uint(m.win_w + 0.5); // 0, 1 or 2 (cycled by the A key)
        float o = m.win_h; // the pixel oversizing (the AA band / quad size)

        if (algo == 0u) {
            // NAIVE SDF: the exact distance at the pixel center + the
            // smoothstep band over the oversize.
            float d = strokeDist(c_s, m.curve_bda);
            float cov = 1.0 - smoothstep(half - o, half + o, d);
            cov = pow(cov, 1.0 / COVERAGE_GAMMA);
            return float4(vColor.rgb, cov * vColor.a);
        }

        if (algo == 2u) {
            // The EXACT CAIRO REFERENCE: the stroke's offset-outline
            // polygon, integrated per pixel via the exact trapezoid
            // coverage — Cairo's covered_height / uncovered_area model.
            // The band's boundary edges (m.curve_bda holds the EDGE buffer
            // for mode 2) cross the pixel; each contributes its signed
            // vertical extent + the exact trapezoid area to the pixel's
            // left edge, and the coverage is |Σ covered_height − Σ
            // uncovered_area|. Exact for the straight edges (the
            // polygonalized offset), no field sampling.
            vk::BufferPointer<EdgeBuf> eb = vk::BufferPointer<EdgeBuf>(m.curve_bda);
            uint ne = eb.Get().count;
            // The pixel's integration window is [cell_s, cell_s+1) — c_s is
            // the CENTER, so the corner is c_s - 0.5. (The audit found the
            // old code integrated [c_s, c_s+1], shifted +0.5px.)
            float px = c_s.x - 0.5;
            float py = c_s.y - 0.5;
            float hsum = 0.0;
            float usum = 0.0;
            for (uint i = 0u; i < ne; i++) {
                Edge e = edgeAt(m.curve_bda, i);
                float ay = e.p0.y;
                float by = e.p1.y;
                float ymin = min(ay, by);
                float ymax = max(ay, by);
                if (ymax <= py || ymin >= py + 1.0) continue;
                float yt = max(ymin, py);
                float yb = min(ymax, py + 1.0);
                float inv = (by == ay) ? 0.0 : 1.0 / (by - ay);
                float xt = e.p0.x + (e.p1.x - e.p0.x) * (yt - ay) * inv;
                float xb = e.p0.x + (e.p1.x - e.p0.x) * (yb - ay) * inv;
                // Clip the edge's x-crossings to the pixel's x-extent so
                // the trapezoid spans only the overlap. Every edge crossing
                // the row contributes here; the band's left/right pairs
                // cancel per pixel (the accumulation the earlier cell-based
                // variants replaced — they degraded the lines).
                xt = clamp(xt, px, px + 1.0);
                xb = clamp(xb, px, px + 1.0);
                float sign = (by > ay) ? 1.0 : -1.0;
                float h = yb - yt;
                hsum += sign * h;
                usum += sign * 0.5 * ((xt - px) + (xb - px)) * h;
            }
            float cov = clamp(abs(hsum - usum), 0.0, 1.0);
            cov = pow(cov, 1.0 / COVERAGE_GAMMA);
            return float4(vColor.rgb, cov * vColor.a);
        }

        // MARCHING QUADS (algo 1): the center's SDF early-out, then the 5 taps
        // (center + 4 corners of the quad, half-extent 0.5+o) resolving
        // the 4 triangles — the covered area / the quad's area.
        float sd_c = sdfStroke(c_s, m.curve_bda, half);
        if (sd_c > 2.0) return float4(vColor.rgb, 0.0);
        if (sd_c < -2.0) return float4(vColor.rgb, vColor.a);
        float hq = 0.5 + o;
        float2 tl = cell_s + float2(0.5 - hq, 0.5 - hq);
        float2 tr = cell_s + float2(0.5 + hq, 0.5 - hq);
        float2 br = cell_s + float2(0.5 + hq, 0.5 + hq);
        float2 bl = cell_s + float2(0.5 - hq, 0.5 + hq);
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
        float quad_area = (2.0 * hq) * (2.0 * hq);
        float cov = clamp(area / quad_area, 0.0, 1.0);
        cov = pow(cov, 1.0 / COVERAGE_GAMMA);
        return float4(vColor.rgb, cov * vColor.a);
    }

    if (m.type == TYPE_ROUNDED_RECT) {
        // Rounded-rect fill (border == 0) or ring (border > 0). Material
        // fields: win_w/win_h = rect size, curve_w/curve_h = corner radii
        // (x/y), bearing_y = border width. vOrigin = the rect top-left in
        // framebuffer px, so fragPos - vOrigin = position in the rect.
        float2 size = float2(m.win_w, m.win_h);
        float2 radius = max(float2(m.curve_w, m.curve_h), float2(0.0));
        // Clamp radii to half the box so the SDF never inverts.
        radius = min(radius, size * 0.5);
        float2 p = fragPos.xy - vOrigin - size * 0.5;
        // Inigo Quilez sdRoundBox: one formula, no branches (sdRoundRect
        // keeps the GLSL's operation order: q = abs(p) - size*0.5 + radius).
        float d = sdRoundRect(p, size, radius);
        float outer = clamp(0.5 - d, 0.0, 1.0);
        float coverage = outer;
        float border = m.bearing_y;
        if (border > 0.0 && border < min(size.x, size.y) * 0.5) {
            // Ring: subtract the inner rounded rect (box inset by the
            // border, corner radius reduced by the border) —
            // sdRoundRectInner keeps the GLSL's order verbatim.
            float id = sdRoundRectInner(p, size, radius, border);
            float inner = clamp(0.5 - id, 0.0, 1.0);
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
        // feather (px, soft-edge width). Same SDF shape as ROUNDED_RECT, but
        // the coverage fades out over the feather instead of the hard 0.5px
        // edge; no ring subtraction. sdShadowRect keeps the GLSL
        // order: hbox = size*0.5 - radius first, then q = abs(p) - hbox.
        float2 size = float2(m.win_w, m.win_h);
        float2 radius = max(float2(m.curve_w, m.curve_h), float2(0.0));
        radius = min(radius, size * 0.5);
        float2 p = fragPos.xy - vOrigin - size * 0.5;
        // Canonical sdRoundBox (the same formula ROUNDED_RECT uses): the
        // inside term min(max(q.x,q.y), 0.0) makes the interior distance
        // the true edge distance. Without it the inside distance is just
        // -r, so zero/thin-radius shadows (r < feather/2) render at
        // 0.5 + r/feather partial opacity instead of saturating.
        float d = sdShadowRect(p, size, radius);
        float coverage = clamp(0.5 - d / max(m.bearing_y, 0.5), 0.0, 1.0);
        return float4(vColor.rgb, coverage * vColor.a);
    }
    return vColor;
}
