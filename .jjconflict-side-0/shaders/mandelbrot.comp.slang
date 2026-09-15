// mandelbrot.comp.slang — a compute Mandelbrot with a RUNTIME PRECISION
// switch. Three modes (the params' `precision` field):
//   0 = f32: full-rate fp32 iteration, zoom capped ~1e7 (the f32 mapping
//            collapses past it).
//   1 = f64: full f64 iteration — deep zoom to ~1e15, but the 1660 Ti's
//            1/32 fp64 rate caps the frame rate at high iteration counts.
//   2 = ADAPTIVE (default): f32 below scale ~1e4 (fast), f64 above (the
//       deep-zoom precision only where the f32 would break).
// The coordinate MAPPING always runs in f64 (cheap, once per pixel); only
// the hot iteration loop switches.
//
// Params ABI: the noapi compute push is ONE u64 — the BDA of a
// host-visible MandelParams buffer (the same pattern as the graphics
// push's BDA fields). Layout is std430 (vk::BufferPointer target):
//   size (uint2, align 8) @ 0, center (double2, align 8) @ 8,
//   scale (double, align 8) @ 24, time (float) @ 32, max_iter (uint) @ 36,
//   precision (uint) @ 40 — 44 bytes, the struct padded to 48.
// The window writes the Zig mirror of this struct verbatim (see
// MandelParams in window.zig).
//
// Entry: main (compute) — loaded with entry "main", [numthreads(8,8,1)];
// the window dispatches (size.x/8, size.y/8, 1) groups.

import lib.color;

static const float TAU = 6.283185307179586;

// The zoom scale at which the f32 iteration loses enough precision to
// matter (well below the ~8e6 mapping collapse; the f64 only pays off above).
static const double ADAPTIVE_THRESHOLD = 1.0e4;

// NB: layout MUST match the Zig MandelParams extern verbatim. The
// center/scale are SCALAR doubles (not double2) on purpose: the Slang
// "natural" (default) layout packs a double2 at an ambiguous offset, and
// the Zig extern's [2]f64 aligns to 8. Two scalar doubles force the same
// 8-aligned offsets in both. Verified against @offsetOf(MandelParams).
struct MandelParams {
    uint2 size; // @0
    double center_x; // @8
    double center_y; // @16
    double scale; // @24
    float time; // @32
    uint max_iter; // @36
    uint precision; // @40 — 0 f32, 1 f64, 2 adaptive
};

struct PushData {
    uint64_t params_bda;
};

[[vk::push_constant]] PushData pc;

// Set 1 binding 0 = the noapi storage-image heap (descHeapSetTexturesRw).
// Non-arrayed: the layout's binding is a descriptor array, but the shader
// uses element 0 only (the same convention as the sweep compute demo), so
// the window writes the mandelbrot's storage view at set-1 index 0.
[[vk::binding(0, 1)]] RWTexture2D<float4> outImage;

[shader("compute")]
[numthreads(8, 8, 1)]
void main(uint3 tid : SV_DispatchThreadID) {
    MandelParams p = vk::BufferPointer<MandelParams>(pc.params_bda).Get();
    if (tid.x >= p.size.x || tid.y >= p.size.y) return;

    // Map the pixel to the complex plane in DOUBLE precision (the mapping
    // `center + offset/scale` loses the tiny offset in f32 at high zoom).
    double2 c = double2(
        p.center_x + (double(tid.x) / double(p.size.x) - 0.5) * (double(p.size.x) / p.scale),
        p.center_y + (double(tid.y) / double(p.size.y) - 0.5) * (double(p.size.y) / p.scale));

    // Iterate z = z^2 + c; escape radius 2.0 (the standard |z|^2 > 4 test).
    // The precision mode selects f32 (full-rate) vs f64 (deep) vs adaptive.
    const bool want_f64 = (p.precision == 1) || (p.precision == 2 && p.scale >= ADAPTIVE_THRESHOLD);
    uint iter = 0;
    float zmag = 0.0;
    if (want_f64) {
        double2 z = double2(0.0);
        for (; iter < p.max_iter; iter++) {
            z = double2(z.x * z.x - z.y * z.y, 2.0 * z.x * z.y) + c;
            if (dot(z, z) > 4.0) break;
        }
        // The magnitude is computed in FLOAT — GLSL.std.450 log2/sqrt only
        // support the 16/32-bit floats, not f64, and the color's smooth
        // count doesn't need the double precision.
        if (iter < p.max_iter) zmag = sqrt(float(z.x) * float(z.x) + float(z.y) * float(z.y));
    } else {
        float2 z = float2(0.0);
        float2 c32 = float2(c);
        for (; iter < p.max_iter; iter++) {
            z = float2(z.x * z.x - z.y * z.y, 2.0 * z.x * z.y) + c32;
            if (dot(z, z) > 4.0) break;
        }
        if (iter < p.max_iter) zmag = sqrt(dot(z, z));
    }

    float4 col;
    if (iter == p.max_iter) {
        // Interior (never escaped): Oklab black.
        col = float4(0.0, 0.0, 0.0, 1.0);
    } else {
        // Log-smooth iteration count: mu = iter + 1 - log2(log2(|z|)).
        // Escaped means |z| > 2, so both log2s are well-defined.
        float mu = float(iter) + 1.0 - log2(log2(zmag));
        // Time-animated hue: the palette wraps every ~50 iterations and
        // drifts with the frame time (time = frame ms / 1000).
        float hue = mu * 0.02 + p.time * 0.1;
        // Linear-sRGB rainbow (cosine palette), converted to Oklab — the
        // pipeline's color space — via lib/color.slang's forward matrix.
        float3 rgb = 0.5 + 0.5 * cos(TAU * (hue + float3(0.0, 0.33, 0.67)));
        float3 lab = linearToOklab(rgb);
        col = float4(lab, 1.0);
    }

    outImage[int2(tid.xy)] = col;
}
