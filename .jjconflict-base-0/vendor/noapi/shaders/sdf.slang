module sdf;
import base;

// DIRECT INTERFACE // 

[Differentiable]
public float sdUnion(float a, float b) {
  return min(a, b);
}

[Differentiable]
public float sdSubtraction(float a, float b) {
  return max(-a, b);
}

[Differentiable]
public float sdIntersection(float a, float b) {
  return max(a, b);
}

[Differentiable]
public float sdXor(float a, float b) {
  return max(min(a, b), -max(a, b));
}

[Differentiable]
public float sdSmoothUnion(float a, float b, float k) {
  k *= 4.0;
  float h = max(k - abs(a - b), 0.0);
  return min(a, b) - h * h * 0.25 / k;
}

[Differentiable]
public float sdSmoothSubtraction(float a, float b, float k) {
  return -sdSmoothUnion(a, -b, k);
}

[Differentiable]
public float sdSmoothIntersection(float a, float b, float k) {
  return -sdSmoothUnion(-a, -b, k);
}

// 2D SDFs // 

// SDF of a circle in 2D
// @param p Test point coordinate
// @param c Center point
// @param r Radius
[Differentiable]
public float sdCircle2D(float2 p, float2 c, float r) {
  return length(p - c) - r;
}

// SDF of a rounded box in 2D
// @param p Test point coordinate
// @param b Center point
// @param r roundness tr, br, tl, bl
[Differentiable]
public float sdRoundedBox2D(float2 p, float2 b, float4 r) {
  r.xy = (p.x > 0.0) ? r.xy : r.zw;
  r.x = (p.y > 0.0) ? r.x : r.y;
  float2 q = abs(p) - b + r.x;
  return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r.x;
}

/// SDF of a chamfered box in 2D
// @param p Test point coordinate
// @param b Center point
// @param chamfer Chamfer distance
[Differentiable]
public float sdChamferBox2D(float2 p, float2 b, float chamfer) {
  p = abs(p) - b;
  p = (p.y > p.x) ? p.yx : p.xy;
  p.y += chamfer;
  const float k = 1.0 - sqrt(2.0);

  if(p.y < 0.0 && p.y + p.x * k < 0.0) return p.x;
  if(p.x < p.y) return (p.x + p.y) * sqrt(0.5);
  return length(p);
}

// SDF of a box in 2D
// @param p Test point coordinate
// @param b Center point
[Differentiable]
public float sdBox2D(float2 p, float2 b) {
  float2 d = abs(p) - b;
  return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
}

// SDF of an oriented box in 2D
// @param p Test point coordinate
// @param a Terminating point 1
// @param b Terminating point 2
// @param th Thickness
[Differentiable]
public float sdOrientedBox2D(float2 p, float2 a, float2 b, float th) {
  float l = length(b - a);
  float2 d = (b - a) / l;
  float2 q = (p - (a+b) * 0.5);
  q = mul(float2x2(d.x, -d.y, d.y, d.x), q);
  q = abs(q) - float2(1, th) * 0.5;
  return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0);
}

/// SDF of a line segment in 2D
// @param p Test point coordinate
// @param a Terminating point 1
// @param b Terminating point 2
[Differentiable]
public float sdSegment2D(float2 p, float2 a, float2 b) {
  float2 pa = p - a;
  float2 ba = b - a;
  float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
  return length(pa - ba * h);
}

[Differentiable]
public float sdRhombus2D(float2 p, float2 b) {
  b.y = -b.y;
  p = abs(p);
  float h = clamp((dot(b, p) + b.y * b.y) / dot(b, b), 0.0, 1.0);
  p -= b * float2(h, h - 1.0);
  return length(p) * sign(p.x);
}

[Differentiable]
public float sdPentagram2D(float2 p, float r) {
  static float k1x = (sqrt(5.0) + 1.0) / 4.0;
  static float k2x = (sqrt(5.0) - 1.0) / 4.0;
  static float k1y = (sqrt(10.0 - 2.0*sqrt(5.0))) / 4.0;
  static float k2y = (sqrt(10.0 + 2.0*sqrt(5.0))) / 4.0;
  static float k1z = (sqrt( 5.0 - 2.0*sqrt(5.0)));
  static float2 v1 = float2( k1x, -k1y);
  static float2 v2 = float2(-k1x, -k1y);
  static float2 v3 = float2( k2x, -k2y);

  p.x = abs(p.x);
  p -= 2.0 * max(dot(v1, p), 0.0)*v1;
  p -= 2.0*max(dot(v2, p), 0.0)*v2;
  p.x = abs(p.x);

  p.y -= r;
  return length(p - v3*clamp(dot(p, v3), 0.0, k1z*r)) * sign(p.y * v3.x - p.x * v3.y);
}

[Differentiable]
public float sdGrid2D(float2 p, float th) {
  float2 u = no_diff fract(p - float2(0.5));
  float2 c = u - float2(0.5);
  return min(abs(c.x), abs(c.y)) - th * 0.5;
}


// 3D SDFs // 

[Differentiable]
public float sdSphere3D(float3 p, float radius) {
  return length(p) - radius;
}

[Differentiable]
public float sdBox3D(float3 p, float3 b) {
  float3 q = abs(p) - b;
  return length(max(q, 0.0)) + min(max(q.x, max(q.y, q.z)), 0.0);
}

[Differentiable]
public float sdRoundedBox3D(float3 p, float3 b, float r) {
  float3 q = abs(p) - b + r;
  return length(max(q, 0.0)) + min(max(q.x, max(q.y, q.z)), 0.0) - r;
}

[Differentiable]
public float sdTorus3D(float3 p, float2 t) {
  float2 q = float2(length(p.xz) - t.x, p.y);
  return length(q) - t.y;
}


// INDIRECT INTERFACE // 

// 2D SDFs //

// interface Sdf2D {
//   [Differentiable]
//   // [ForceInline]
//   float operator()(float2 p);

//   float2 normal(float2 p) {
//     return _normal(this, p);
//   }

//   [Differentiable]
//   static float _distance<T: Sdf2D>(T t, float2 p) {
//     return t(p);
//   }

//   [Differentiable]
//   static float2 _normal<T: Sdf2D>(T t, float2 p) {
//     var dp = diffPair(p, float2(1));
//     // float output = 1;
//     bwd_diff(_distance)(t, dp, 1);
//     return dp.d;
//   }
// };

// 3D SDFs // 

// interface Sdf3D {
//   [Differentiable]
//   // [ForceInline]
//   float operator()(float3 p);

//   float3 normal(float3 p) {
//     return _normal(this, p);
//   }

//   [Differentiable]
//   static float _distance<T: Sdf3D>(T t, float3 p) {
//     return t(p);
//   }

//   static float3 _normal<T: Sdf3D>(T t, float3 p) {
//     // DifferentialPair<float3> dp = diffPair(p, float3(1));
//     var dp = diffPair(p, float3(1));
//     float output = float(1);
//     bwd_diff(_distance)(t, dp, output);
//     return dp.d;
//   }

// };
public interface Sdf<let N: int> {
  // typedef vector<float, N> floatN;
  // typedef Sdf<N> SdfN;
  [Differentiable]
  // [ForceInline]
  float operator()(vector<float, N> p);

  vector<float, N> normal(vector<float, N> p) {
    return _normal(this, p);
  }

  [Differentiable]
  static float _distance(This t, vector<float, N> p) {
    return t(p);
  }

  static vector<float, N> _normal(This t, vector<float, N> p) {
    // DifferentialPair<float3> dp = diffPair(p, float3(1));
    var dp = diffPair(p, vector<float, N>(1));
    float output = float(1);
    bwd_diff(_distance)(t, dp, output);
    return dp.d;
  }

  __generic<Lhs: Sdf<N>, Rhs: Sdf<N>>
  _Union<N, Lhs, Rhs> operator+(Lhs lhs, Rhs rhs) {
    return {lhs, rhs};
  }
};

public typedef Sdf<1> Sdf1d;
public typedef Sdf<2> Sdf2d;
public typedef Sdf<3> Sdf3d;
public typedef Sdf<4> Sdf4d;

__generic<let N: int, Lhs: Sdf<N>, Rhs: Sdf<N>>
_Union<N, Lhs, Rhs> operator+(Lhs lhs, Rhs rhs) {
  return {lhs, rhs};
}

__generic<let N: int, Lhs: Sdf<N>, Rhs: Sdf<N>>
_Subtraction<N, Lhs, Rhs> operator-(Lhs lhs, Rhs rhs) {
  return {lhs, rhs};
}

public struct _Union<let N: int, A: Sdf<N>, B: Sdf<N>> : Sdf<N> {
  A a;
  B b;
  __init(A lhs, B rhs) { a = lhs; b = rhs; }
  [Differentiable]
  float operator()(vector<float, N> p) {
    return min(a(p), b(p));
  }
}

public func union<let N: int, A: Sdf<N>, B: Sdf<N>>(A a, B b) -> _Union<N, A, B> {
  return {a, b};
  // _Union<N, A, B> res;
  // res.a = a;
  // res.b = b;
  // return res;
  // return _Union<N, A, B>(a, b); // (a, b);
}

public struct _Subtraction<let N: int, A: Sdf<N>, B: Sdf<N>> : Sdf<N> {
  A a;
  B b;
  public __init(A lhs, B rhs) { a = lhs; b = rhs; }

  [Differentiable]
  float operator()(vector<float, N> p) {
    return min(a(p), -b(p));
  }
}

// [Differentiable]
public func subtraction<let N: int, A: Sdf<N>, B: Sdf<N>>(A a, B b) -> _Subtraction<N, A, B> {
  return {a, b};
}

public struct _Repetition<let N: int, T: Sdf<N>> : Sdf<N> {
  T primitive;
  vector<float, N> s;
  public __init(T prim, vector<float, N> S) { primitive = prim; s = S; }

  [Differentiable]
  float operator()(vector<float, N> p) {
    vector<float, N> q = p - s * no_diff round(p / s);
    return primitive(q);
  }
}

public func repetition<let N: int, T: Sdf<N>>(T primitive, vector<float, N> s) -> _Repetition<N, T> {
  return {primitive, s};
}

public struct _LimitedRepetition<let N: int, T: Sdf<N>> : Sdf<N> {
  T primitive;
  vector<float, N> s;
  vector<float, N> l;
  __init(T prim, vector<float, N> S, vector<float, N> L) { primitive = prim; s = S; l = L; }

  [Differentiable]
  float operator()(vector<float, N> p) {
    vector<float, N> q = p - s * clamp(no_diff round(p/s), -l, l);
    return primitive(q);
  }  
}

public func limitedRepetition<let N: int, T: Sdf<N>>(T primitive, vector<float, N> s, vector<float, N> l) -> _LimitedRepetition<N, T> {
  // _LimitedRepetition<N, T> res;
  // res.s = s;
  // res.l = l;
  // res.primitive = primitive;
  // return res;
  return {primitive, s, l};
  
  // return {primitive, s, l};
}

public struct Sphere3d : Sdf3d {
  float radius;
  public __init(float rad) { radius = rad; }

  [Differentiable]
  float operator()(float3 p) {
    return length(p) - radius;
  }
}

public struct Quad3d : Sdf3d {
  float3 a;
  float3 b;
  float3 c;
  float3 d;
  public __init(float3 A, float3 B, float3 C, float3 D) { a = A; b = B; c = C; d = D; }
  [Differentiable]
  float operator()(float3 p) {
    float3 ba = b - a;
    float3 pa = p - a;
    float3 cb = c - b;
    float3 pb = p - b;
    float3 dc = d - c;
    float3 pc = p - c;
    float3 ad = a - d;
    float3 pd = p - d;
    float3 nor = cross(ba, ad);

    return sqrt(
      (
        sign(dot(cross(ba, nor), pa)) +
        sign(dot(cross(cb, nor), pb)) +
        sign(dot(cross(dc, nor), pc)) +
        sign(dot(cross(ad, nor), pd)) < 3)
        ?
        min(min(min(
          dot2(ba * clamp(dot(ba, pa) / dot2(ba), 0, 1) - pa),
          dot2(cb * clamp(dot(cb, pb) / dot2(cb), 0, 1) - pb) ),
          dot2(dc * clamp(dot(dc, pc) / dot2(dc), 0, 1) - pc) ),
          dot2(ad * clamp(dot(ad, pd) / dot2(ad), 0, 1) - pd) )
        :
        dot(nor, pa) * dot(nor, pa) / dot2(nor)
    );
  }
}

public struct Box3d : Sdf3d {
  float3 b;
  [Differentiable]
  float operator()(float3 p) {
    float3 q = abs(p) - b;
    return length(max(q, 0)) + min(max(q.x, max(q.y, q.z)), 0);
  }
}

public struct RoundedBox3d : Sdf3d {
  float3 b;
  float r;
  [Differentiable]
  float operator()(float3 p) {
    float3 q = abs(p) - b + r;
    return length(max(q, 0)) + min(max(q.x, max(q.y, q.z)), 0) - r;
  }
}

public struct Torus3d : Sdf3d {
  float2 t;
  public __init(float2 param) { t = param; }
  [Differentiable]
  float operator()(float3 p) {
    float2 q = float2(length(p.xz) - t.x, p.y);
    return length(q) - t.y;
  }
}
