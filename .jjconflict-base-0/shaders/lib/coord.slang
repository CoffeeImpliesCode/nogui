// coord.slang — pure coordinate/SDF helpers for quad_frag.
//
// Bit-exact ports of the SDF math that quad_frag.glsl evaluates inline in
// main(). Each helper preserves the EXACT float operation order of the GLSL
// branch it came from — do not "simplify" or reorder (the acceptance gate is
// a pixel-compare against the GLSL build). The coverage clamps
// (clamp(0.5 - d, ...), the feather division) and the cell/window math stay
// in the fragment shader.

// Canonical Inigo Quilez sdRoundBox — the formula both TYPE_ROUNDED_RECT
// and TYPE_SHADOW evaluate (q = abs(p) - b; the inside term
// min(max(q.x,q.y), 0.0) makes the interior distance the true edge distance).
public float sdRoundBox(float2 p, float2 b, float r) {
    float2 q = abs(p) - b;
    return min(max(q.x, q.y), 0.0) + length(max(q, float2(0.0))) - r;
}

// TYPE_ROUNDED_RECT outer distance. The GLSL computes q as
// abs(p) - size * 0.5 + radius (NOT abs(p) - (size * 0.5 - radius)) —
// keep that operation order bit-exact.
public float sdRoundRect(float2 p, float2 size, float2 radius) {
    float2 q = abs(p) - size * 0.5 + radius;
    float r = min(radius.x, radius.y);
    return min(max(q.x, q.y), 0.0) + length(max(q, float2(0.0))) - r;
}

// TYPE_ROUNDED_RECT ring: the inner rounded rect subtracted from the outer
// (box inset by the border, corner radius reduced by the border). GLSL order:
// inner_radius = max(radius - border, 0); q = abs(p) - (size*0.5 - border)
// + inner_radius.
public float sdRoundRectInner(float2 p, float2 size, float2 radius, float border) {
    float2 inner_radius = max(radius - border, float2(0.0));
    float2 iq = abs(p) - (size * 0.5 - border) + inner_radius;
    float ir = min(inner_radius.x, inner_radius.y);
    return min(max(iq.x, iq.y), 0.0) + length(max(iq, float2(0.0))) - ir;
}

// TYPE_SHADOW distance. GLSL order: hbox = size * 0.5 - radius computed
// FIRST, then q = abs(p) - hbox, with min(radius.x, radius.y) inline in the
// final expression.
public float sdShadowRect(float2 p, float2 size, float2 radius) {
    float2 hbox = size * 0.5 - radius;
    float2 q = abs(p) - hbox;
    return min(max(q.x, q.y), 0.0) + length(max(q, float2(0.0))) - min(radius.x, radius.y);
}
