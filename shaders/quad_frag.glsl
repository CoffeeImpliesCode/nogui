#version 460
#extension GL_EXT_buffer_reference : require
#extension GL_ARB_gpu_shader_int64 : require

layout(location = 0) in vec2 vUv;
layout(location = 1) in vec4 vColor;
layout(location = 2) flat in uint vMaterialIdx;
layout(location = 3) in vec2 vOrigin; // rect top-left in framebuffer px

layout(location = 0) out vec4 fragColor;

const int TYPE_SOLID = 0;
const int TYPE_GLYPH = 1;
const int TYPE_ROUNDED_RECT = 2;
const int TYPE_SHADOW = 3;

struct GlyphMaterial {
    int type;
    float bearing_y;
    float curve_w;
    float curve_h;
    float win_w;
    float win_h;
    uint64_t curve_bda;
    vec4 gradient_to; // gradient bottom color (Oklab); .w > 0 enables the gradient
};

layout(buffer_reference, buffer_reference_align = 8) buffer MaterialBuf {
    GlyphMaterial materials[];
};

struct QuadCurve {
    vec2 p0;
    vec2 p1;
    vec2 p2;
};

layout(buffer_reference, buffer_reference_align = 16) buffer CurveBuf {
    uint num_curves;
    uint pad;
    QuadCurve curves[];
};

layout(buffer_reference, buffer_reference_align = 4) buffer ByteBuf {
    uint data[];
};

// ── Analytic curve sweep (per-fragment coverage) ────────────────────────
// The glyph outlines are swept at DISPLAY resolution: each fragment is a
// 1x1 window at (gl_FragCoord - vOrigin), the coverage is the summed fill
// of the glyph's quadratics. No intermediate bitmap — the AA is exact at
// any (sub-pixel) placement, which the CPU-bitmap path could never match.
// (This is the v4 pipeline's scanlineSweep, ported back into the shader.)
float sweepIntersect(float qa, float c0, float c1, float c2, float target) {
    if (abs(qa) < 1e-3) return (target - c0) / (c2 - c0);
    float qb = 2.0 * (c1 - c0);
    float qc = c0 - target;
    float d = qb * qb - 4.0 * qa * qc;
    float sqrt_d = (d < 0.0) ? 0.0 : sqrt(d);
    float inv_2a = 0.5 / qa;
    float sgn = (c2 - c0 > 0.0) ? 1.0 : -1.0;
    return -qb * inv_2a + sgn * sqrt_d * inv_2a;
}

vec2 sweepEval(vec2 p0, vec2 p1, vec2 p2, float t) {
    float mt = 1.0 - t;
    return vec2(mt * mt * p0.x + 2.0 * mt * t * p1.x + t * t * p2.x,
                mt * mt * p0.y + 2.0 * mt * t * p1.y + t * t * p2.y);
}

float sweepSegment(vec2 size, vec2 offset, vec2 p0, vec2 p1, vec2 p2) {
    if (max(p0.y, p2.y) <= offset.y || min(p0.y, p2.y) >= offset.y + size.y) return 0.0;
    vec2 delta = p2 - p0;
    vec2 t0 = p0 - offset;
    vec2 t1 = p1 - offset;
    vec2 t2 = p2 - offset;
    if (t0.x == t1.x && t0.x == t2.x) {
        if (t0.x >= size.x) return 0.0;
        float top = min(max(t0.y, t2.y), size.y);
        float bottom = max(min(t0.y, t2.y), 0.0);
        float b = min(size.x, size.x - t0.x);
        float sgn = (delta.y > 0.0) ? 1.0 : -1.0;
        return sgn * b * (top - bottom);
    }
    float qa_y = t0.y + t2.y - 2.0 * t1.y;
    float bt = sweepIntersect(qa_y, t0.y, t1.y, t2.y, 0.0);
    float tt = sweepIntersect(qa_y, t0.y, t1.y, t2.y, size.y);
    float v_min_t = (delta.y > 0.0) ? bt : tt;
    float v_max_t = (delta.y > 0.0) ? tt : bt;
    vec2 v_min = sweepEval(t0, t1, t2, clamp(v_min_t, 0.0, 1.0));
    vec2 v_max = sweepEval(t0, t1, t2, clamp(v_max_t, 0.0, 1.0));
    if (max(v_min.x, v_max.x) <= 0.0) return (v_max.y - v_min.y) * size.x;
    if (min(v_min.x, v_max.x) >= size.x) return 0.0;
    float qa_x = t0.x + t2.x - 2.0 * t1.x;
    float h_min_t = 0.0;
    float h_max_t = 0.0;
    vec4 h_check = (delta.x > 0.0) ? vec4(t0.x, t2.x, 0.0, 0.0) : vec4(t2.x, t0.x, size.x, 1.0);
    if (h_check.x >= h_check.z) {
        h_min_t = h_check.w;
    } else if (h_check.y <= h_check.z) {
        h_min_t = 1.0 - h_check.w;
    } else {
        h_min_t = sweepIntersect(qa_x, t0.x, t1.x, t2.x, h_check.z);
    }
    h_check.z = size.x - h_check.z;
    if (h_check.x >= h_check.z) {
        h_max_t = h_check.w;
    } else if (h_check.y <= h_check.z) {
        h_max_t = 1.0 - h_check.w;
    } else {
        h_max_t = sweepIntersect(qa_x, t0.x, t1.x, t2.x, h_check.z);
    }
    float min_t = clamp(max(v_min_t, h_min_t), 0.0, 1.0);
    float max_t = clamp(min(v_max_t, h_max_t), 0.0, 1.0);
    if (min_t >= max_t) return 0.0;
    vec2 q0 = (v_min_t >= h_min_t) ? v_min : sweepEval(t0, t1, t2, min_t);
    vec2 q1 = (v_max_t <= h_max_t) ? v_max : sweepEval(t0, t1, t2, max_t);
    float area = 0.0;
    float sgn_y = (delta.y > 0.0) ? 1.0 : -1.0;
    if (min_t > 0.0 && delta.x > 0.0) {
        float h_ = (delta.y > 0.0) ? q0.y - max(0.0, t0.y) : min(size.y, t0.y) - q0.y;
        area += sgn_y * h_ * size.x;
    }
    if (max_t < 1.0 && delta.x < 0.0) {
        float h_ = (delta.y > 0.0) ? min(size.y, t2.y) - q1.y : q1.y - max(0.0, t2.y);
        area += sgn_y * h_ * size.x;
    }
    float h_trap = q1.y - q0.y;
    float b_trap = size.x - 0.5 * (q0.x + q1.x);
    area += b_trap * h_trap;
    return area;
}

// Coverage bitmap texel (1 byte, row-major, row 0 = glyph top).
float texelCoverage(uint64_t bda, uint n, uint x, uint y, uint bmp_w) {
    ByteBuf bytes = ByteBuf(bda);
    uint bit_off = 8u + n * 24u + y * bmp_w + x;
    uint word = bytes.data[bit_off / 4u];
    uint byte_val = (word >> (8u * (bit_off % 4u))) & 0xFFu;
    return clamp(float(byte_val) / 255.0, 0.0, 1.0);
}

// Bilinear reconstruction of the pre-AA'd coverage bitmap. Glyph quads sit
// at fractional (sub-pixel) pen positions — the canonical HarfBuzz output —
// so nearest sampling would snap each glyph's ink to the pixel grid
// independently: uneven gaps, jitter on moving text, lost kerning.
float sampleCoverage(uint64_t bda, uint n, float bmp_w, float bmp_h, vec2 cell) {
    float cx = clamp(cell.x - 0.5, 0.0, bmp_w - 1.0);
    float cy = clamp(cell.y - 0.5, 0.0, bmp_h - 1.0);
    float fx = fract(cx);
    float fy = fract(cy);
    uint x = uint(cx);
    uint y = uint(cy);
    uint x1 = min(x + 1u, uint(bmp_w) - 1u);
    uint y1 = min(y + 1u, uint(bmp_h) - 1u);
    float c00 = texelCoverage(bda, n, x, y, uint(bmp_w));
    float c10 = texelCoverage(bda, n, x1, y, uint(bmp_w));
    float c01 = texelCoverage(bda, n, x, y1, uint(bmp_w));
    float c11 = texelCoverage(bda, n, x1, y1, uint(bmp_w));
    return mix(mix(c00, c10, fx), mix(c01, c11, fx), fy);
}

layout(push_constant) uniform Push {
    uint64_t material_buf_bda;
    uint64_t vp_h_packed;
} pc;

// ── Scanline Sweeper (§8.2–8.3) ───────────────────────────
float intersectMonotonic(float qa, float c0, float c1, float c2, float target) {
    if (abs(qa) < 1e-3) {
        // Approximately linear (matches paper threshold)
        return (target - c0) / (c2 - c0);
    }
    float qb = 2.0 * (c1 - c0);
    float qc = c0 - target;
    float d = qb*qb - 4.0*qa*qc;
    float sqrt_d = d < 0.0 ? 0.0 : sqrt(d);
    float inv_2a = 0.5 / qa;
    return -qb * inv_2a + sign(c2 - c0) * sqrt_d * inv_2a;
}

vec2 evalBez(vec2 p0, vec2 p1, vec2 p2, float t) {
    float mt = 1.0 - t;
    return mt*mt*p0 + 2.0*mt*t*p1 + t*t*p2;
}

float scanlineSweep(vec2 size, vec2 offset, vec2 p0, vec2 p1, vec2 p2) {
    if (max(p0.y, p2.y) <= offset.y || min(p0.y, p2.y) >= offset.y + size.y) return 0.0;
    vec2 delta = p2 - p0;
    p0 -= offset; p1 -= offset; p2 -= offset;
    if (p0.x == p1.x && p0.x == p2.x) {
        if (p0.x >= size.x) return 0.0;
        float top = min(max(p0.y, p2.y), size.y);
        float bottom = max(min(p0.y, p2.y), 0.0);
        float b = min(size.x, size.x - p0.x);
        return sign(delta.y) * b * (top - bottom);
    }
    float qa_y = p0.y + p2.y - 2.0 * p1.y;
    float bt = intersectMonotonic(qa_y, p0.y, p1.y, p2.y, 0.0);
    float tt = intersectMonotonic(qa_y, p0.y, p1.y, p2.y, size.y);
    float v_min_t = delta.y > 0.0 ? bt : tt;
    float v_max_t = delta.y > 0.0 ? tt : bt;
    vec2 v_min = evalBez(p0, p1, p2, clamp(v_min_t, 0.0, 1.0));
    vec2 v_max = evalBez(p0, p1, p2, clamp(v_max_t, 0.0, 1.0));
    if (max(v_min.x, v_max.x) <= 0.0) return (v_max.y - v_min.y) * size.x;
    if (min(v_min.x, v_max.x) >= size.x) return 0.0;
    float qa_x = p0.x + p2.x - 2.0 * p1.x;
    float h_min_t, h_max_t;
    vec4 h_check = delta.x > 0.0 ? vec4(p0.x, p2.x, 0.0, 0.0) : vec4(p2.x, p0.x, size.x, 1.0);
    if (h_check.x >= h_check.z)      h_min_t = h_check.w;
    else if (h_check.y <= h_check.z) h_min_t = 1.0 - h_check.w;
    else h_min_t = intersectMonotonic(qa_x, p0.x, p1.x, p2.x, h_check.z);
    h_check.z = size.x - h_check.z;
    if (h_check.x >= h_check.z)      h_max_t = h_check.w;
    else if (h_check.y <= h_check.z) h_max_t = 1.0 - h_check.w;
    else h_max_t = intersectMonotonic(qa_x, p0.x, p1.x, p2.x, h_check.z);
    float min_t = clamp(max(v_min_t, h_min_t), 0.0, 1.0);
    float max_t = clamp(min(v_max_t, h_max_t), 0.0, 1.0);
    if (min_t >= max_t) return 0.0;
    vec2 q0 = (v_min_t >= h_min_t) ? v_min : evalBez(p0, p1, p2, min_t);
    vec2 q1 = (v_max_t <= h_max_t) ? v_max : evalBez(p0, p1, p2, max_t);
    float area = 0.0;
    if (min_t > 0.0 && delta.x > 0.0) {
        float h_ = delta.y > 0.0 ? q0.y - max(0.0, p0.y) : min(size.y, p0.y) - q0.y;
        area += sign(delta.y) * h_ * size.x;
    }
    if (max_t < 1.0 && delta.x < 0.0) {
        float h_ = delta.y > 0.0 ? min(size.y, p2.y) - q1.y : q1.y - max(0.0, p2.y);
        area += sign(delta.y) * h_ * size.x;
    }
    float h_trap = q1.y - q0.y;
    float b_trap = size.x - 0.5 * (q0.x + q1.x);
    area += b_trap * h_trap;
    return area;
}

void main() {
    if (vMaterialIdx == 0u) { fragColor = vColor; return; }

    uint mat_idx = vMaterialIdx; // writeMaterial stores glyph materials at their slot
    MaterialBuf buf = MaterialBuf(pc.material_buf_bda);
    GlyphMaterial mat = buf.materials[mat_idx];

    if (mat.type == TYPE_SOLID) { fragColor = vColor; return; }

    if (mat.type == TYPE_GLYPH) {
        CurveBuf curves = CurveBuf(mat.curve_bda);
        uint n = curves.num_curves;

        // Analytic per-fragment coverage: each fragment is a 1x1 window;
        // the coverage is the summed fill of the glyph's quadratics at
        // DISPLAY resolution — exact AA at any (sub-pixel) placement, no
        // intermediate bitmap. The outline curves are in y-UP font space,
        // so the cell's y is flipped about the bearing (the glyph's top
        // distance above the baseline): framebuffer cell.y = 0 at the top
        // maps to curve y = bearing_y.
        vec2 cell = vec2(gl_FragCoord.x - vOrigin.x,
                         mat.bearing_y - (gl_FragCoord.y - vOrigin.y) - 1.0);
        float total = 0.0;
        for (uint i = 0u; i < n; i++) {
            QuadCurve cv = curves.curves[i];
            total += sweepSegment(vec2(1.0), cell, cv.p0, cv.p1, cv.p2);
        }
        float coverage = clamp(total, 0.0, 1.0);
        fragColor = vec4(vColor.rgb, coverage * vColor.a);
        return;
    }

    if (mat.type == TYPE_ROUNDED_RECT) {
        // Rounded-rect fill (border == 0) or ring (border > 0). Material
        // fields: win_w/win_h = rect size, curve_w/curve_h = corner radii
        // (x/y), bearing_y = border width. vOrigin = the rect top-left in
        // framebuffer px, so gl_FragCoord - vOrigin = position in the rect.
        vec2 size = vec2(mat.win_w, mat.win_h);
        vec2 radius = max(vec2(mat.curve_w, mat.curve_h), vec2(0.0));
        // Clamp radii to half the box so the SDF never inverts.
        radius = min(radius, size * 0.5);
        vec2 p = gl_FragCoord.xy - vOrigin - size * 0.5;
        // Inigo Quilez sdRoundBox: one formula, no branches. Inside the
        // inset box (q <= 0) the distance is to the nearest straight edge
        // (the true distance, correct for radius 0 too); beyond it the
        // distance is to the corner arc. Branchy "true-distance" rewrites
        // of the corner region measure against the arc's FULL circle, whose
        // continuation past the visible quarter makes fragments several px
        // inside the box read as near-boundary — stray 50-80% coverage
        // pixels at the corners ("dirty inset").
        vec2 q = abs(p) - size * 0.5 + radius;
        float r = min(radius.x, radius.y);
        float d = min(max(q.x, q.y), 0.0) + length(max(q, vec2(0.0))) - r;
        float outer = clamp(0.5 - d, 0.0, 1.0);
        float coverage = outer;
        float border = mat.bearing_y;
        if (border > 0.0 && border < min(size.x, size.y) * 0.5) {
            // Ring: subtract the inner rounded rect (box inset by the
            // border, corner radius reduced by the border). Same canonical
            // sdRoundBox (iq): the inner rect's b = size/2 - border.
            vec2 inner_radius = max(radius - border, vec2(0.0));
            vec2 iq = abs(p) - (size * 0.5 - border) + inner_radius;
            float ir = min(inner_radius.x, inner_radius.y);
            float id = min(max(iq.x, iq.y), 0.0) + length(max(iq, vec2(0.0))) - ir;
            float inner = clamp(0.5 - id, 0.0, 1.0);
            coverage = clamp(outer - inner, 0.0, 1.0);
        }
        // Vertical gradient: gradient_to.w > 0 enables the mix. vUv.y = 0
        // at the top, 1 at the bottom; vColor.rgb is the gradient top.
        vec3 rgb = vColor.rgb;
        if (mat.gradient_to.w > 0.0) {
            rgb = mix(vColor.rgb, mat.gradient_to.rgb, clamp(vUv.y, 0.0, 1.0));
        }
        fragColor = vec4(rgb, coverage * vColor.a);
        return;
    }

    if (mat.type == TYPE_SHADOW) {
        // Feathered rounded-rect shadow. win_w/win_h = the shadow rect size,
        // curve_w/curve_h = the widget's corner radii, bearing_y = the
        // feather (px, soft-edge width). Same SDF shape as ROUNDED_RECT, but
        // the coverage fades out over the feather instead of the hard 0.5px
        // edge; no ring subtraction.
        vec2 size = vec2(mat.win_w, mat.win_h);
        vec2 radius = max(vec2(mat.curve_w, mat.curve_h), vec2(0.0));
        radius = min(radius, size * 0.5);
        vec2 p = gl_FragCoord.xy - vOrigin - size * 0.5;
        vec2 hbox = size * 0.5 - radius;
        vec2 q = abs(p) - hbox;
        float d = length(max(q, vec2(0.0))) - min(radius.x, radius.y);
        float coverage = clamp(0.5 - d / max(mat.bearing_y, 0.5), 0.0, 1.0);
        fragColor = vec4(vColor.rgb, coverage * vColor.a);
        return;
    }
    fragColor = vColor;
}
