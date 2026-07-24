#version 460
#extension GL_EXT_buffer_reference : require
#extension GL_ARB_gpu_shader_int64 : require

layout(location = 0) in vec2 vUv;
layout(location = 1) in vec4 vColor;
layout(location = 2) flat in uint vMaterialIdx;

layout(location = 0) out vec4 fragColor;

const int TYPE_SOLID = 0;
const int TYPE_GLYPH = 1;
const int TYPE_ROUNDED_RECT = 2;

struct GlyphMaterial {
    int type;
    float bearing_y;
    float curve_w;
    float curve_h;
    float win_w;
    float win_h;
    uint64_t curve_bda;
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

    uint mat_idx = vMaterialIdx - 1u;
    MaterialBuf buf = MaterialBuf(pc.material_buf_bda);
    GlyphMaterial mat = buf.materials[mat_idx];

    if (mat.type == TYPE_SOLID) { fragColor = vColor; return; }

    if (mat.type == TYPE_GLYPH) {
        CurveBuf curves = CurveBuf(mat.curve_bda);
        uint n = curves.num_curves;

        // Pixel window in curve space: center from interpolated UV,
        // size from dFdx/dFdy (UV change per screen pixel).
        vec2 win_size = vec2(abs(dFdx(vUv).x), abs(dFdy(vUv).y));
        vec2 offset = vUv - 0.5 * win_size;

        // Subpixel AA: 7 Harmony-style evaluations (full pixel width)
        // shifted by -1/3, 0, +1/3, ... for adjacent pixel subpixel
        // positions, then ClearType 5-tap per-channel filter.
        bool saa = false;
        if (saa) {
            float third_x = win_size.x / 3.0;

            // 7 evaluations with full pixel width at shifted positions
            float c[7];
            for (int k = 0; k < 7; k++) {
                vec2 o = offset;
                o.x += float(k - 1) * third_x;
                float t = 0.0;
                for (uint i = 0u; i < n; i++)
                    t += scanlineSweep(win_size, o, curves.curves[i].p0,
                                                      curves.curves[i].p1,
                                                      curves.curves[i].p2);
                float area = win_size.x * win_size.y;
                c[k] = area > 0.0 ? clamp(t / area, 0.0, 1.0) : 0.0;
            }

            // ClearType 5-tap per-channel filter
            const float w_a = 0.03125;
            const float w_b = 0.30078125;
            const float w_c = 0.3359375;

            float r = w_a*c[0] + w_b*c[1] + w_c*c[2] + w_b*c[3] + w_a*c[4];
            float g = w_a*c[1] + w_b*c[2] + w_c*c[3] + w_b*c[4] + w_a*c[5];
            float b = w_a*c[2] + w_b*c[3] + w_c*c[4] + w_b*c[5] + w_a*c[6];
            float luma = (r + g + b) / 3.0;
            fragColor = vec4(r, g, b, luma);
        } else {
            float total = 0.0;
            for (uint i = 0u; i < n; i++) {
                total += scanlineSweep(win_size, offset, curves.curves[i].p0,
                                                        curves.curves[i].p1,
                                                        curves.curves[i].p2);
            }
            float win_area = win_size.x * win_size.y;
            float coverage = win_area > 0.0 ? clamp(total / win_area, 0.0, 1.0) : 0.0;
            fragColor = vec4(0.0, 0.0, 0.0, coverage);
        }
        return;
    }
    fragColor = vColor;
}
