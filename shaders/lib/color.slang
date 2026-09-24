// Color conversions shared by the glyph fragment pass and the final blit.
// Keep the matrix products and gamma operations in this order for pixel
// parity. The final blit converts the Oklab target to linear sRGB.
module color;

// Oklab -> LINEAR sRGB (Björn Ottosson's inverse, direct cubic form).
public func oklabToSRGB(float3 lab) -> float3 {
    float l_ = lab.x + 0.3963377774 * lab.y + 0.2158037573 * lab.z;
    float m_ = lab.x - 0.1055613458 * lab.y - 0.0638541728 * lab.z;
    float s_ = lab.x - 0.0894841775 * lab.y - 1.2914855480 * lab.z;
    float3 lms = float3(l_, m_, s_) * float3(l_, m_, s_) * float3(l_, m_, s_);
    return float3(
        +4.0767416621 * lms.x - 3.3077115913 * lms.y + 0.2309699292 * lms.z,
        -1.2684380046 * lms.x + 2.6097574011 * lms.y - 0.3413193965 * lms.z,
        -0.0041960863 * lms.x - 0.7034186147 * lms.y + 1.7076147010 * lms.z
    );
}

// LINEAR sRGB -> Oklab (Ottosson's forward conversion).
public func linearToOklab(float3 rgb) -> float3 {
    float l = 0.4122214708 * rgb.r + 0.5363325363 * rgb.g + 0.0514459929 * rgb.b;
    float m = 0.2119034982 * rgb.r + 0.6806995451 * rgb.g + 0.1073969566 * rgb.b;
    float s = 0.0883024619 * rgb.r + 0.2817188376 * rgb.g + 0.6299787005 * rgb.b;
    float lp = pow(l, 1.0 / 3.0);
    float mp = pow(m, 1.0 / 3.0);
    float sp = pow(s, 1.0 / 3.0);
    return float3(
        0.2104542553 * lp + 0.7936177850 * mp - 0.0040720468 * sp,
        1.9779984951 * lp - 2.4285922050 * mp + 0.4505937099 * sp,
        0.0259040371 * lp + 0.7827717662 * mp - 0.8086757660 * sp
    );
}
