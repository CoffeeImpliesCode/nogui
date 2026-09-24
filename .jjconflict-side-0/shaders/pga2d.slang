module pga2d;
interface Vector {
    property s: float;
  };


public struct Pga2d : Vector {
  // public vector<float, 8> v;
  // property s: float { get { return v[0]; } set { v[0] = newValue; } };
  // property e0: float { get { return v[1]; } set { v[1] = newValue; } };
  // property e1: float { get { return v[2]; } set { v[2] = newValue; } };
  // property e2: float { get { return v[3]; } set { v[3] = newValue; } };
  // property e01: float { get { return v[4]; } set { v[4] = newValue; } };
  // property e12: float { get { return v[5]; } set { v[5] = newValue; } };
  // property e20: float { get { return v[6]; } set { v[6] = newValue; } };
  // property e012: float { get { return v[7]; } set { v[7] = newValue; } };
  public float s;
  public float e0;
  public float e1;
  public float e2;
  public float e01;
  public float e12;
  public float e20;
  public float e012; 


  property point: float3 { get { return float3(e01, e20, e12); } };
  property line: float3 { get { return float3(e1, e2, e0); } };
  
  // __subscript(int idx) -> float { get { return v[idx]; } set { v[idx] = newValue; } }  
};
public static const Pga2d S = {1, 0, 0, 0, 0, 0, 0, 0};
public static const Pga2d E0 = {0, 1, 0, 0, 0, 0, 0, 0};
public static const Pga2d E1 = {0, 0, 1, 0, 0, 0, 0, 0};
public static const Pga2d E2 = {0, 0, 0, 1, 0, 0, 0, 0};
public static const Pga2d E01 = {0, 0, 0, 0, 1, 0, 0, 0};
public static const Pga2d E12 = {0, 0, 0, 0, 0, 1, 0, 0};
public static const Pga2d E20 = {0, 0, 0, 0, 0, 0, 1, 0};
public static const Pga2d E012 = {0, 0, 0, 0, 0, 0, 0, 1};

public static const Pga2d p2zero = {0, 0, 0, 0, 0, 0, 0, 0};
public static const Pga2d p2origin = {0, 0, 0, 0, 0, 0, 0, 1};

public Pga2d operator+(Pga2d lhs, Pga2d rhs) {
  return {
    lhs.s + rhs.s,
    lhs.e0 + rhs.e0,
    lhs.e1 + rhs.e1,
    lhs.e2 + rhs.e2,
    lhs.e01 + rhs.e01,
    lhs.e12 + rhs.e12,
    lhs.e20 + rhs.e20,
    lhs.e012 + rhs.e012,
  };
}
public Pga2d operator+(Pga2d lhs, float rhs) {
  return {
    lhs.s + rhs,
    lhs.e0 + rhs,
    lhs.e1 + rhs,
    lhs.e2 + rhs,
    lhs.e01 + rhs,
    lhs.e12 + rhs,
    lhs.e20 + rhs,
    lhs.e012 + rhs,
  };
}
public Pga2d operator+(float lhs, Pga2d rhs) {
  return {
    lhs + rhs.s,
    lhs + rhs.e0,
    lhs + rhs.e1,
    lhs + rhs.e2,
    lhs + rhs.e01,
    lhs + rhs.e12,
    lhs + rhs.e20,
    lhs + rhs.e012,
  };
}

public Pga2d operator-(Pga2d lhs, Pga2d rhs) {
  return {
    lhs.s - rhs.s,
    lhs.e0 - rhs.e0,
    lhs.e1 - rhs.e1,
    lhs.e2 - rhs.e2,
    lhs.e01 - rhs.e01,
    lhs.e12 - rhs.e12,
    lhs.e20 - rhs.e20,
    lhs.e012 - rhs.e012,
  };
}
public Pga2d operator-(Pga2d lhs, float rhs) {
  return {
    lhs.s - rhs,
    lhs.e0 - rhs,
    lhs.e1 - rhs,
    lhs.e2 - rhs,
    lhs.e01 - rhs,
    lhs.e12 - rhs,
    lhs.e20 - rhs,
    lhs.e012 - rhs,
  };
}
public Pga2d operator-(float lhs, Pga2d rhs) {
  return {
    lhs - rhs.s,
    lhs - rhs.e0,
    lhs - rhs.e1,
    lhs - rhs.e2,
    lhs - rhs.e01,
    lhs - rhs.e12,
    lhs - rhs.e20,
    lhs - rhs.e012,
  };
}
public __prefix Pga2d operator-(Pga2d v) {
  return {
    -v.s,
    -v.e0,
    -v.e1,
    -v.e2,
    -v.e01,
    -v.e12,
    -v.e20,
    -v.e012,
  };
}

// Reverse Operator
public __prefix Pga2d operator~(Pga2d v) {
  return {
    v.s,
    v.e0,
    v.e1,
    v.e2,
    -v.e01,
    -v.e12,
    -v.e20,
    -v.e012,
  };
}

public Pga2d operator*(Pga2d lhs, float rhs) {
  return {
    lhs.s * rhs,
    lhs.e0 * rhs,
    lhs.e1 * rhs,
    lhs.e2 * rhs,
    lhs.e01 * rhs,
    lhs.e12 * rhs,
    lhs.e20 * rhs,
    lhs.e012 * rhs,
  };
}
public Pga2d operator*(float lhs, Pga2d rhs) {
  return {
    lhs * rhs.s,
    lhs * rhs.e0,
    lhs * rhs.e1,
    lhs * rhs.e2,
    lhs * rhs.e01,
    lhs * rhs.e12,
    lhs * rhs.e20,
    lhs * rhs.e012,
  };
}
public Pga2d operator*(Pga2d lhs, Pga2d rhs) {
  return mul(lhs, rhs);
}
public Pga2d operator/(Pga2d lhs, float rhs) {
  return lhs * (1/rhs);
}

public Pga2d p2scalar(float val) {
  return {val, 0, 0, 0, 0, 0, 0, 0};
}

public Pga2d line(float3 h) {
  return {0, h.z, h.x, h.y, 0, 0, 0, 0};
}

public Pga2d point(float2 p) {
  return {0, 0, 0, 0, p.y, 1, p.x, 0};
}

public Pga2d idealPoint(float2 p) {
  return {0, 0, 0, 0, p.y, 0, p.x, 0};;
}

public Pga2d rotor(float angle, float2 c) {
  float half = angle * 0.5;
  var r = p2scalar(cos(half)) + (E12 * sin(half));
  if(c.x == 0 && c.y == 0) return r;
  else {
    var t = translator(c);
    return mul(mul(t, r), conj(t));
  }
}

public Pga2d translator(float2 dp) {
  var dir = idealPoint(dp);
  return p2scalar(1) + (0.5 * dir);
}

public Pga2d meet(Pga2d a, Pga2d b) {
  return {
    b.s * a.s,
    b.e0 * a.s + b.s * a.e0,
    b.e1 * a.s + b.s * a.e1,
    b.e2 * a.s + b.s * a.e2,
    b.e01 * a.s + b.e1 * a.e0 - b.e0 * a.e1 + b.s * a.e01,
    b.e12 * a.s - b.e2 * a.e1 - b.e1 * a.e2 + b.s * a.e12,
    b.e20 * a.s - b.e2 * a.e0 + b.e0 * a.e2 + b.s * a.e20,
    b.e012 * a.s + b.e12 * a.e0 + b.e20 * a.e1 + b.e01 * a.e2 + b.e2 * a.e01 + b.e1 * a.e20 + b.e0 * a.e12 + b.s * a.e012,
  };
}

public Pga2d join(Pga2d a, Pga2d b) {
  return {
    a.s   * b.e012 + a.e0  * b.e12 + a.e1  * b.e20 + a.e2   * b.e01 + a.e01 * b.e2 + a.e20 * b.e1 + a.e12 * b.e0 + a.e012 * b.s,
    a.e0  * b.e012 + a.e01 * b.e20 - a.e20 * b.e01 + a.e012 * b.e0,
    a.e1  * b.e012 - a.e01 * b.e12 + a.e12 * b.e01 + a.e012 * b.e1,
    a.e2  * b.e012 + a.e20 * b.e12 - a.e12 * b.e20 + a.e012 * b.e2,
    a.e01 * b.e012 + a.e012 * b.e01,
    a.e12 * b.e012 + a.e012 * b.e12,
    a.e20 * b.e012 + a.e012 * b.e20,
    a.e012 * b.e012,
  };
}

public Pga2d dot(Pga2d a, Pga2d b) {
  return {
    b.s * a.s + b.e1 * a.e1 + b.e2 * a.e2 - b.e12 * a.e12,
    b.e0 * a.s + b.s * a.e0 - b.e01 * a.e1 + b.e20 * a.e2 + b.e1 * a.e01 - b.e2 * a.e20 - b.e012 * a.e12 - b.e12 * a.e012,
    b.e1 * a.s + b.s * a.e1 - b.e12 * a.e2 + b.e2 * a.e12,
    b.e2 * a.s + b.e12 * a.e1 + b.s * a.e2 - b.e1 * a.e12,
    b.e01 * a.s + b.e012 * a.e2 + b.s * a.e01 + b.e2 * a.e012,
    b.e12 * a.s + b.s * a.e12,
    b.e20 * a.s + b.e012 * a.e1 + b.s * a.e20 + b.e1 * a.e012,
    b.e012 * a.s + b.s * a.e012,
  };
}

public Pga2d mul(Pga2d a, Pga2d b) {
  return {
    b.s * a.s + b.e1 * a.e1 + b.e2 * a.e2 - b.e12 * a.e12,
    b.e0 * a.s + b.s * a.e0 - b.e01 * a.e1 + b.e20 * a.e2 + b.e1 * a.e01 - b.e2 * a.e20 - b.e012 * a.e12 - b.e12 * a.e012,
    b.e1 * a.s + b.s * a.e1 - b.e12 * a.e2 + b.e2 * a.e12,
    b.e2 * a.s + b.e12 * a.e1 + b.s * a.e2 - b.e1 * a.e12,
    b.e01 * a.s + b.e1 * a.e0 - b.e0 * a.e1 + b.e012 * a.e2 + b.s * a.e01 + b.e12 * a.e20 - b.e20 * a.e12 + b.e2 * a.e012,
    b.e12 * a.s + b.e2 * a.e1 - b.e1 * a.e2 + b.s * a.e12,
    b.e20 * a.s - b.e2 * a.e0 + b.e012 * a.e1 + b.e0 * a.e2 - b.e12 * a.e01 + b.s * a.e20 + b.e01 * a.e12 + b.e1 * a.e012,
    b.e012 * a.s + b.e12 * a.e0 + b.e20 * a.e1 + b.e01 * a.e2 + b.e2 * a.e01 + b.e1 * a.e20 + b.e0 * a.e12 + b.s * a.e012,
  };
}

public Pga2d dual(Pga2d v) {
  return {
    v.e012, v.e20, v.e12, v.e01, v.e2, v.e1, v.e0, v.s
  };
}

public Pga2d conj(Pga2d v) {
  return {
    v.s,
    -v.e0, -v.e1, -v.e2,
    -v.e01, -v.e12, -v.e20,
    v.e012
  };
}

public Pga2d invol(Pga2d v) {
  return {
    v.s,
    -v.e0, -v.e1, -v.e2,
    v.e01, v.e12, v.e20,
    -v.e012
  };
}

public Pga2d normalize(Pga2d v) {
  var spart = mul(v, conj(v)).s;
  var norm  = sqrt(abs(spart));
  return v / norm;
}

public float length(Pga2d v) {
  var spart = mul(v, conj(v)).s;
  return sqrt(abs(spart));
}
