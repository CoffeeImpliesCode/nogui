module base;

// public static float TAU = 6.283185307;
public static float PI = float.getPi();
public static float TAU = float.getPi() * 2;


public static float2 FULLQUAD[6] = float2[](
  float2(-1.0, -1.0),
  float2(1.0, 1.0),
  float2(-1.0, 1.0),
  float2(-1.0, -1.0),
  float2(1.0, 1.0),
  float2(1.0, -1.0),
);

// remap uv [0..1] x [0..1] to math [-1..1] x [-ar/2..ar/2] 
public float2 uv2math(float2 uv, float aspect) {
  return (uv - float2(0.5)) * float2(1, -aspect);
}

[Differentiable]
public func dot2<T: __BuiltinFloatingPointType, int N>(vector<T, N> v) -> T {
  return dot(v, v);
}


