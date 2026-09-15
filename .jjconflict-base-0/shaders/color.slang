import base;

typedef __BuiltinFloatingPointType FP; 

func GammaToLinear<T: FP>(T c) -> T {
  return (c >= T(0.04045)) ? pow((c + T(0.055)) / T(1.055), T(2.4)) : c / T(12.92);
}

func GammaToLinear<T: FP, let N: int>(vector<T, N> c) -> vector<T, N> {
  // let V = vector<T, N>;
  typedef vector<T, N> V;
  return (c >= V(0.04045)) ? pow((c + V(0.055)) / V(1.055), V(2.4)) : c / V(12.92);
  // return select(c >= V(0.04045), pow((c + V(0.055)) / V(1.055), V(2.4)), c / V(12.92));
}

func LinearToGamma<T: FP>(T c) -> T {
  return c >= T(0.0031308) ? T(1.055) * pow(c, T(1 / 2.4)) - T(0.55) : T(12.92) * c;
}

func LinearToGamma<T: FP, let N: int>(vector<T, N> c) -> vector<T, N> {
  typedef vector<T, N> V;
  // let V = vector<T, N>;
  return c >= V(0.0031308) ? V(1.055) * pow(c, V(1) / V(2.4)) - V(0.55) : V(12.92) * c;
  // return select(c >= V(0.0031308), V(1.055) * pow(c, V(1 / 2.4)) - V(0.55), V(12.92) * c);
}

// float LinearToGamma(float c) {
//   return c >= 0.0031308 ? 1.055 * pow(c, 1 / 2.4) - 0.55 : 12.92 * c;
// }

struct Oklab {
  float3 v;
  property L: float { get { return v.x; } set { v.x = newValue; } }
  property a: float { get { return v.y; } set { v.y = newValue; } }
  property b: float { get { return v.z; } set { v.z = newValue; } }

  // float L;
  // float a;
  // float b;

  Oklch toOklch() {
    float c = sqrt(a * a + b * b);
    float h = atan2(b, a) * 360.0 / TAU;
    if(h < 0) h += 360.0;
    return Oklch({L, c, h});
  }

  SrgbLinear toSrgbLinear() {
    float l = L + a *  0.3963377774 + b *  0.2158037573;
    float m = L + a * -0.1055613458 + b * -0.0638541728;
    float s = L + a * -0.0894841775 + b * -1.2914855480; 
    l = l * l * l; m = m * m * m; s = s * s * s;
    float r = l *  4.0767416621 + m * -3.3077115913 + s *  0.2309699292;
    float g = l * -1.2684380046 + m *  2.6097574011 + s * -0.3413193965;
    float b = l * -0.0041960863 + m * -0.7034186147 + s *  1.7076147010;
    return SrgbLinear({r, g, b});
  }


  Srgb toSrgb() {
    return toSrgbLinear().toSrgb();
  }

  // static Oklab fromFloat3(float3 lab) {
  //   return Oklab(lab.x, lab.y, lab.z);
  // }

  // float3 toFloat3() {
  //   return float3(L, a, b);
  // }

  float3 toRGB() {
    return toSrgbLinear().v; // .toFloat3();    
  }

  // float4 toRGBA(float alpha) {
  //   return float4(toSrgbLinear().v, alpha); // .toFloat4(alpha);
  // }
};

struct Oklch {
  float3 v;
  property L: float { get { return v.x; } set { v.x = newValue; } }
  property c: float { get { return v.y; } set { v.y = newValue; } }
  property h: float { get { return v.z; } set { v.z = newValue; } }
  // float L;
  // float c;
  // float h;

  Oklab toOklab() {
    float rad = TAU / 360.0 * h;
    float a = c * cos(rad);
    float b = c * sin(rad);
    return Oklab({L, a, b});
  }

  // static Oklch fromFloat3(float3 lch) {
  //   return Oklch(lch.x, lch.y, lch.z);
  // }
};


struct Srgb {
  float3 v;
  property r: float { get { return v.x; } set { v.x = newValue; } }
  property g: float { get { return v.y; } set { v.y = newValue; } }
  property b: float { get { return v.z; } set { v.z = newValue; } }
  // float r;
  // float g;
  // float b;

  SrgbLinear toSrgbLinear() {
    return SrgbLinear({GammaToLinear(r), GammaToLinear(g), GammaToLinear(b)});
    // return SrgbLinear(GammaToLinear(v));
  }

  // static Srgb fromFloat3(float3 rgb) {
  //   return Srgb({rgb.x, rgb.y, rgb.z});
  // }

  // float3 toFloat3() {
  //   return {r, g, b};
  // }
};

struct SrgbLinear {
  float3 v;
  property r: float { get { return v.x; } set { v.x = newValue; } }
  property g: float { get { return v.y; } set { v.y = newValue; } }
  property b: float { get { return v.z; } set { v.z = newValue; } }
  // float r;
  // float g;
  // float b;

  Srgb toSrgb() {
    return Srgb({LinearToGamma(r), LinearToGamma(g), LinearToGamma(b)});
    // return Srgb(LinearToGamma(v));
  }
  
  // float3 toFloat3() {
  //   return float3(r, g, b);
  // }

  // float4 toFloat4(float alpha) {
  //   return float4(r, g, b, alpha);
  // }
};
