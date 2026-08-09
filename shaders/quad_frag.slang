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
// texelCoverage (135-141), sampleCoverage (147-161), and the scanline
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
// never copy CurveBuf by value, and NEVER use a member array: Slang emits
// a wrong ArrayStride for arrays in physical-storage-buffer structs (8 for
// the unsized form, 98312 = the whole struct for the fixed form), so the
// sweep would read garbage. curveAt builds a fresh BufferPointer per
// element — the address arithmetic is the contract: header 8 bytes
// ([u32 count][u32 pad]), then 24-byte QuadCurves.
struct CurveBuf {
    uint num_curves;
    uint pad;
};

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
        // and cutting its bottom/right by the same amount. vOrigin for
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
        // columns and sweep each (the display's RGB stripes in that
        // order: left = R, middle = G, right = B). The output chroma is
        // the barycentric mix of the three PRIMARIES' ab coordinates
        // weighted by the column coverages (Oklab primaries: R(0.2249,
        // 0.1258), G(-0.2339, 0.1795), B(-0.0325, -0.3115)); the
        // luminance is the mean coverage (l+m+r)/3, boosted by the
        // fragment's own average RGB over white so the text renders at
        // full brightness, and carried by the alpha for compositing.
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
            // multiplies by avg again, and without this the edge pixels
            // double-darken.
            float L = clamp(lab.x / max(avg, 1e-3), 0.0, 1.0);
            // Chroma damping ≈ FreeType's 5-tap LCD filter in one line:
            // keep the luminance detail (the sharpness), kill the fringe
            // color (raw column coverages fringe maximally). Tune 0.2-0.5;
            // bit 3 of frag_data disables it (the full-chroma order test).
            if ((pc.frag_data & uint64_t(8)) != uint64_t(0)) lab.yz *= 0.3;
            return float4(L, lab.y, lab.z, avg * vColor.a);
        }

        float total = 0.0;
        for (uint i = 0u; i < n; i++) {
            QuadCurve cv = curveAt(m.curve_bda, i);
            total += sweepSegment(float2(1.0), cell, cv.p0, cv.p1, cv.p2);
        }
        float coverage = clamp(total, 0.0, 1.0);
        return float4(vColor.rgb, coverage * vColor.a);
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
