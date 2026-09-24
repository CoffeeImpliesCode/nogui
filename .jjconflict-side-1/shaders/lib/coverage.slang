module coverage;

// ── Analytic curve sweep (per-fragment coverage) ────────────────────────
// Ported BIT-EXACT from shaders/quad_frag.glsl (the v4 analytic glyph sweep).
// The glyph outlines are swept at DISPLAY resolution: each fragment is a
// 1x1 window at (gl_FragCoord - vOrigin), the coverage is the summed fill
// of the glyph's quadratics. No intermediate bitmap — the AA is exact at
// any (sub-pixel) placement, which the CPU-bitmap path could never match.
//
// What quad_frag.glsl actually calls: only sweepSegment — the TYPE_GLYPH
// branches call it at line ~302 (color coverage), ~322-324 (sub-pixel
// triple-column coverage), and ~358 (alpha coverage). sweepEval and
// sweepIntersect are its internal helpers.
//
// scanlineSweep + evalBez + intersectMonotonic are the §8.2-8.3 scanline
// sweeper: still present in quad_frag.glsl (line ~219) but with no call
// sites there (its canonical callers are the v4 pipeline's sweep.comp /
// sweep.frag), so it is ported here for completeness, not consumed by the
// fragment shader. intersectMonotonic carries the NaN guard (c2 == c0
// returns 0.0 — degenerate horizontal segment, reachable from line_cb's
// collinear midpoint quadratics).
//
// GLSL → Slang mapping: vec2/vec4 → float2/float4, abs/max/min/clamp/
// sqrt/sign unchanged, ternary and per-component [0]/[1] indexing kept.
// No reformulation, no fused ops, same division order, same 1e-3 epsilons.

// sweepSegment's quadratic-root helper (no NaN guard — matches GLSL).
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

float2 sweepEval(float2 p0, float2 p1, float2 p2, float t) {
    float mt = 1.0 - t;
    return float2(mt * mt * p0.x + 2.0 * mt * t * p1.x + t * t * p2.x,
                  mt * mt * p0.y + 2.0 * mt * t * p1.y + t * t * p2.y);
}

// Signed fill area of one quadratic over the window [offset, offset+size].
// This is what the fragment shader's TYPE_GLYPH branches call.
public float sweepSegment(float2 size, float2 offset, float2 p0, float2 p1, float2 p2) {
    if (max(p0.y, p2.y) <= offset.y || min(p0.y, p2.y) >= offset.y + size.y) return 0.0;
    float2 delta = p2 - p0;
    float2 t0 = p0 - offset;
    float2 t1 = p1 - offset;
    float2 t2 = p2 - offset;
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
    float2 v_min = sweepEval(t0, t1, t2, clamp(v_min_t, 0.0, 1.0));
    float2 v_max = sweepEval(t0, t1, t2, clamp(v_max_t, 0.0, 1.0));
    if (max(v_min.x, v_max.x) <= 0.0) return (v_max.y - v_min.y) * size.x;
    if (min(v_min.x, v_max.x) >= size.x) return 0.0;
    float qa_x = t0.x + t2.x - 2.0 * t1.x;
    float h_min_t = 0.0;
    float h_max_t = 0.0;
    float4 h_check = (delta.x > 0.0) ? float4(t0.x, t2.x, 0.0, 0.0) : float4(t2.x, t0.x, size.x, 1.0);
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
    float2 q0 = (v_min_t >= h_min_t) ? v_min : sweepEval(t0, t1, t2, min_t);
    float2 q1 = (v_max_t <= h_max_t) ? v_max : sweepEval(t0, t1, t2, max_t);
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

// ── Scanline Sweeper (§8.2-8.3) ───────────────────────────
// Note: GLSL signature is (float qa, float c0, float c1, float c2,
// float target) — five params, not four; kept EXACT.
float intersectMonotonic(float qa, float c0, float c1, float c2, float target) {
    if (abs(qa) < 1e-3) {
        // Approximately linear (matches paper threshold)
        // Degenerate horizontal segment (c2 == c0): the division is 0/0 →
        // NaN, which pollutes the coverage; line_cb emits collinear
        // midpoint quadratics so this is reachable. The sweep is then
        // unconstrained in t, so return 0.0.
        if (c2 == c0) return 0.0;
        return (target - c0) / (c2 - c0);
    }
    float qb = 2.0 * (c1 - c0);
    float qc = c0 - target;
    float d = qb*qb - 4.0*qa*qc;
    float sqrt_d = d < 0.0 ? 0.0 : sqrt(d);
    float inv_2a = 0.5 / qa;
    return -qb * inv_2a + sign(c2 - c0) * sqrt_d * inv_2a;
}

float2 evalBez(float2 p0, float2 p1, float2 p2, float t) {
    float mt = 1.0 - t;
    return mt*mt*p0 + 2.0*mt*t*p1 + t*t*p2;
}

float scanlineSweep(float2 size, float2 offset, float2 p0, float2 p1, float2 p2) {
    if (max(p0.y, p2.y) <= offset.y || min(p0.y, p2.y) >= offset.y + size.y) return 0.0;
    float2 delta = p2 - p0;
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
    float2 v_min = evalBez(p0, p1, p2, clamp(v_min_t, 0.0, 1.0));
    float2 v_max = evalBez(p0, p1, p2, clamp(v_max_t, 0.0, 1.0));
    if (max(v_min.x, v_max.x) <= 0.0) return (v_max.y - v_min.y) * size.x;
    if (min(v_min.x, v_max.x) >= size.x) return 0.0;
    float qa_x = p0.x + p2.x - 2.0 * p1.x;
    float h_min_t, h_max_t;
    float4 h_check = delta.x > 0.0 ? float4(p0.x, p2.x, 0.0, 0.0) : float4(p2.x, p0.x, size.x, 1.0);
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
    float2 q0 = (v_min_t >= h_min_t) ? v_min : evalBez(p0, p1, p2, min_t);
    float2 q1 = (v_max_t <= h_max_t) ? v_max : evalBez(p0, p1, p2, max_t);
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

// ── Stroke distance (TYPE_STROKE) ───────────────────────────────────────
// The EXACT point-to-quadratic distance — Inigo Quilez's closed form
// (minimize |B(t)-p|^2 by solving the cubic f'(t)=0 via Cardano). One
// real root (h >= 0) or three (h < 0, the cosine form); the t's clamp to
// [0,1] and the best is kept.
public float distQuad(float2 p, float2 p0, float2 p1, float2 p2) {
    float2 a = p1 - p0;
    float2 b = p0 - 2.0 * p1 + p2;
    float2 c = 2.0 * a;
    float2 d = p0 - p;
    float bb = dot(b, b);
    // Degenerate: a straight line (the collinear midpoint conic) — the
    // exact distance to the segment, avoiding the 1/0.
    if (bb < 1e-12) {
        float2 ab = p2 - p0;
        float len2 = dot(ab, ab);
        if (len2 < 1e-12) return length(d);
        float t = clamp(dot(-d, ab) / len2, 0.0, 1.0);
        float2 q = p0 + t * ab - p;
        return length(q);
    }
    float kk = 1.0 / bb;
    float kx = kk * dot(a, b);
    float ky = kk * (2.0 * dot(a, a) + dot(d, b)) / 3.0;
    float kz = kk * dot(d, a);
    float res = 0.0;
    float p = ky - kx * kx;
    float p3 = p * p * p;
    float q = kx * (2.0 * kx * kx - 3.0 * ky) + kz;
    float h = q * q + 4.0 * p3;
    if (h >= 0.0) {
        h = sqrt(h);
        float2 x = float2(h, -h) - q;
        x *= 0.5;
        float2 uv = sign(x) * pow(abs(x), float2(1.0 / 3.0));
        // The depressed root is z = u + v (the cube roots of the two
        // quadratics), so t = z - kx — NOT u^2+v^2.
        float t = clamp(uv.x + uv.y - kx, 0.0, 1.0);
        float2 qp = d + (c + b * t) * t;
        res = dot(qp, qp);
    } else {
        float z = sqrt(-p);
        float v = acos(q / (p * z * 2.0)) / 3.0;
        float m = cos(v);
        float n = sin(v) * 1.732050808;
        float3 t = clamp(float3(m + m, -n - m, n - m) * z - kx, 0.0, 1.0);
        float2 q1 = d + (c + b * t.x) * t.x;
        float2 q2 = d + (c + b * t.y) * t.y;
        float2 q3 = d + (c + b * t.z) * t.z;
        res = min(dot(q1, q1), min(dot(q2, q2), dot(q3, q3)));
    }
    return sqrt(res);
}
