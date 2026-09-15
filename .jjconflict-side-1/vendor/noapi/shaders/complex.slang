import base;

struct complex {
  float r;
  float i;

  float mag() {
    return sqrt(r * r + i * i);
  }
  float magsq() {
    return r * r + i * i;
  }

  float arg() {
    return atan2(i, r);
  }

  complex sqrt() {
    float abs = mag();
    return complex(sqrt((abs + r) * 0.5), sign(i) * sqrt((abs - r) * 0.5));
  }

  // exp(a + b*i) = exp(a)exp(bi) = exp(a) * (cos(b) + i sin(b)) 
  complex exp() {
    return exp(r) * complex(cos(i), sin(i));
  }

  // log(z) = ln|z| + i Arg z
  complex log() {
    return complex(log(mag()), arg()); 
  }
  // z^s = exp(log(z) * s)
  complex pow(complex s) {
    return (log() * s).exp();
  }

  float2 coord() {
    return float2(r, i);
  }
};

static complex Re = {1, 0};
static complex Im = {0, 1};

// complex addition
complex operator+(complex a, complex b) {
  return complex(a.r + b.r, a.i + b.i);
}
complex operator+(complex a, float b) {
  return complex(a.r + b, a.i);
}
complex operator+(float a, complex b) {
  return complex(a + b.r, b.i);
}
// complex subtration
complex operator-(complex a, complex b) {
  return complex(a.r - b.r, a.i - b.i);
}
complex operator-(complex a, float b) {
  return complex(a.r - b, a.i);
}
complex operator-(float a, complex b) {
  return complex(a - b.r, b.i);
}
// complex negation
complex operator-(complex c) {
  return complex(-c.r, -c.i);
}
// complex multiplication 
complex operator*(complex a, complex b) {
  return complex(a.r * b.r - a.i * b.i, a.r * b.i + a.i * b.r);
}
complex operator*(float a, complex b) {
  return complex(a * b.r, a * b.i);
}
complex operator*(complex a, float b) {
  return complex(a.r * b, a.i * b);
}
// complex division
complex operator/(complex a, complex b) {
  float m = b.r * b.r + b.i * b.i;
  return complex(a.r*b.r + a.i * b.i, a.i * b.r - a.r * b.i) / m;
}
// complex-float division
complex operator/(complex a, float b) {
  return complex(a.r / b, a.i / b);
}
complex operator/(float a, complex b) {
  return complex(a, 0) / b;
}
// complex conjugation
__prefix complex operator~(complex a) {
  return complex(a.r, -a.i);
}

import color;

Oklch DomainColor(complex z) {
  // return Oklch(0.6366197724 * atan(z.mag()), 0.1, (z.arg() + 0.33333 * TAU) / TAU * 360);
  return Oklch({0.6366197724 * atan(z.mag()), 0.10, (z.arg()) / TAU * 360});
}
