#version 460
#extension GL_EXT_buffer_reference : require
#extension GL_ARB_gpu_shader_int64 : require

layout(location = 0) out vec4 fragColor;

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

layout(push_constant) uniform Push {
    uint64_t curve_addr;
    int viewport_height;
    int _pad;
} pc;

// ── Intersection helpers (from paper §8.2) ──────────────────
float intersectMonotonic(float qa, float c0, float c1, float c2, float target) {
    if (abs(qa) < 1e-10) {
        float qb = 2.0 * (c1 - c0);
        if (abs(qb) < 1e-10) return 0.0;
        return (target - c0) / qb;
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

// ── Core sweep (from paper §8.3, with §8.3 bug fix) ───────
float scanlineSweep(vec2 size, vec2 offset, vec2 p0, vec2 p1, vec2 p2) {
    if (max(p0.y, p2.y) <= offset.y || min(p0.y, p2.y) >= offset.y + size.y)
        return 0.0;

    vec2 delta = p2 - p0;
    p0 -= offset; p1 -= offset; p2 -= offset;

    // Vertical line fast path
    if (p0.x == p1.x && p0.x == p2.x) {
        if (p0.x >= size.x) return 0.0;
        float top = min(max(p0.y, p2.y), size.y);
        float bottom = max(min(p0.y, p2.y), 0.0);
        return sign(delta.y) * (size.x - p0.x) * (top - bottom);
    }

    // Y-intersections
    float qa_y = p0.y + p2.y - 2.0 * p1.y;
    float bt = intersectMonotonic(qa_y, p0.y, p1.y, p2.y, 0.0);
    float tt = intersectMonotonic(qa_y, p0.y, p1.y, p2.y, size.y);
    float v_min_t = delta.y > 0.0 ? bt : tt;
    float v_max_t = delta.y > 0.0 ? tt : bt;
    vec2 v_min = evalBez(p0, p1, p2, clamp(v_min_t, 0.0, 1.0));
    vec2 v_max = evalBez(p0, p1, p2, clamp(v_max_t, 0.0, 1.0));

    if (max(v_min.x, v_max.x) <= 0.0) return (v_max.y - v_min.y) * size.x;
    if (min(v_min.x, v_max.x) >= size.x) return 0.0;

    // X-intersections
    float qa_x = p0.x + p2.x - 2.0 * p1.x;
    float h_min_t, h_max_t;
    vec4 h_check = delta.x > 0.0
        ? vec4(p0.x, p2.x, 0.0, 0.0)
        : vec4(p2.x, p0.x, size.x, 1.0);

    if (h_check.x >= h_check.z)      h_min_t = h_check.w;
    else if (h_check.y <= h_check.z) h_min_t = 1.0 - h_check.w;
    else h_min_t = intersectMonotonic(qa_x, p0.x, p1.x, p2.x, h_check.z);

    h_check.z = size.x - h_check.z;
    if (h_check.x >= h_check.z)      h_max_t = h_check.w;
    else if (h_check.y <= h_check.z) h_max_t = 1.0 - h_check.w; // ← §8.3 bug fix
    else h_max_t = intersectMonotonic(qa_x, p0.x, p1.x, p2.x, h_check.z);

    float min_t = clamp(max(v_min_t, h_min_t), 0.0, 1.0);
    float max_t = clamp(min(v_max_t, h_max_t), 0.0, 1.0);
    if (min_t >= max_t) return 0.0;

    vec2 q0 = (v_min_t >= h_min_t) ? v_min : evalBez(p0, p1, p2, min_t);
    vec2 q1 = (v_max_t <= h_max_t) ? v_max : evalBez(p0, p1, p2, max_t);

    float area = 0.0;
    if (min_t > 0.0 && delta.x > 0.0) {
        float h = delta.y > 0.0 ? q0.y - max(0.0, p0.y) : min(size.y, p0.y) - q0.y;
        area += sign(delta.y) * h * size.x;
    }
    if (max_t < 1.0 && delta.x < 0.0) {
        float h = delta.y > 0.0 ? min(size.y, p2.y) - q1.y : q1.y - max(0.0, p2.y);
        area += sign(delta.y) * h * size.x;
    }
    float h_trap = q1.y - q0.y;
    float b_trap = size.x - 0.5 * (q0.x + q1.x);
    area += b_trap * h_trap;
    return area;
}

void main() {
    ivec2 coord = ivec2(gl_FragCoord.xy);
    int vp_h = pc.viewport_height;

    CurveBuf buf = CurveBuf(pc.curve_addr);
    uint n = buf.num_curves;

    // Pixel window in FreeType Y-up space.
    // gl_FragCoord.y = 0 at top → FreeType y = vp_h - 1 - coord.y at top
    // Lower-left corner of pixel: (coord.x, coord.y) → offset.y = vp_h - 2 - coord.y
    vec2 offset = vec2(float(coord.x), float(vp_h - 2 - coord.y));
    vec2 win_size = vec2(1.0, 1.0);

    float total_area = 0.0;
    for (uint i = 0u; i < n; i++) {
        total_area += scanlineSweep(win_size, offset, buf.curves[i].p0, buf.curves[i].p1, buf.curves[i].p2);
    }

    float coverage = clamp(total_area, 0.0, 1.0);
    fragColor = vec4(coverage, coverage, coverage, 1.0);
}
