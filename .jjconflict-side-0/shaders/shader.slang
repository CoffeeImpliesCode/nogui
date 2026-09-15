import base;
import complex;
import color;
import sdf;
import pga2d;

// static float PI = float.getPi();
// static float TAU = float.getPi() * 2;
static float L = 0.74;
static float chroma = 0.0973;
static float3 colors_lch[6] = float3[] (
  float3(L, chroma, 108.9),
  float3(L, chroma, 0.0),
  float3(L, chroma, 156.82),  
  float3(L, chroma, 108.9),
  float3(L, chroma, 0.0),
  float3(L, chroma, 234.8),  
);

struct SceneInfo {
  float4x4 camera;
  float2   window;
  float2   mouse;
  float2   offset;
  float    scale;
  float    time;
};

struct PushConstants {
  const Ptr<SceneInfo> scene_info;
  float2 mouse_position;  
};

struct VertexOutput {
  float4 sv_position: SV_Position;
  float3 color;
};

float3 icosahedron(int idx) {
  int tri = idx / 3;
  int idx = idx % 3;
  int diamond = tri / 2;
  int top = tri % 2;
  int col = diamond / 2;
  int row = diamond % 2;
  int neg = 2 * top - 1;

  int ui = (2 * col + row + 1) - (2 * (idx % 2) - 1 + (idx / 2)) * neg;
  int vi = (row + 1) + (idx / 2) * neg;

  float u = ui / 10.0;
  float v = vi / 3.0;

  float lon = u * TAU;
  float lat = (-v + 0.5) * PI;

  return {cos(lon) * cos(lat), sin(lon) * cos(lat), sin(lat)}; 
}

[shader("vertex")]
VertexOutput vertMain(
  uniform const PushConstants push_constants,
  // uniform MousePosition mouse_position,
  uint vid: SV_VertexID,
) {
  SceneInfo scene = *(push_constants.scene_info);
  VertexOutput output;
  // var cam = transpose(scene.camera);
  var cam = scene.camera;
  output.sv_position = mul(cam, float4(icosahedron(vid), 1.0));
  output.color = Oklch({0.7, 0.1, 10*(vid / 3)}).toOklab().toSrgbLinear().v;
  // output.sv_position = mul(cam, float4(FULLQUAD[vid], 0.0, 1.0));
  // output.color       = Oklch(colors_lch[vid]).toOklab().v;
  return output;
}

struct FragmentOutput {
  float4 frag_color: SV_Target;
};

[shader("fragment")]
FragmentOutput fragMain(
  uniform const PushConstants push_constants,
  // uniform MousePosition mouse_position,
  VertexOutput inVert,
) {
  FragmentOutput res;
  SrgbLinear color;
  SceneInfo scene = *(push_constants.scene_info);
  // scene.mouse = push_constants.mouse_position;
  float4 pos = inVert.sv_position;
  color = SrgbLinear(inVert.color);
  // shader_data.mouse_position = mouse_position.pos;
  // color = raymarcher(inVert.sv_position, scene);
  // color = pgaTest(inVert.sv_position, scene);
  // color = simpleSDFImage(inVert.sv_position, scene);
  // color = colorTest(pos, scene);
  // color = mandelbrotImage(inVert.sv_position, scene).toSrgbLinear();
  // color = {1, 0, 0};
  // color = interp(pos, scene);
  res.frag_color = float4(color.v, 1.0); // .toSrgb().v, 1.0);
  // res.frag_color = float4(Srgb(color).toSrgbLinear().v, 1.0); // .toSrgb().v, 1.0);
  // res.frag_color = float4(Oklab.fromFloat3(color).toSrgbLinear().v, 1.0);
  return res;
}

bool isRGB(SrgbLinear color) {
  return all(saturate(color.v) == color.v);
}

SrgbLinear interp(float4 position, SceneInfo scene) {
  float  t      = scene.time;
  float2 win    = scene.window;
  float  scale  = exp(-scene.scale * 0.5 + 1);
  float  aspect = win.y / win.x;
  float2 offset = scale * scene.offset / win * float2(1, aspect);
  float2 xy     = position.xy / win;
  // float2 xy     = scale * uv2math(position.xy / win, aspect) - offset;
  float2 mouse  = scale * uv2math(scene.mouse / win, aspect) - offset;
  float  px     = length(ddx(xy));
  SrgbLinear color;
  int case = (int)floor(xy.y*5);
  // color = Oklch({0.6, 0.1, case*30}).toOklab().toSrgbLinear();
  // return color;

  // color = Oklab(float3(0.5, xy*0.15 - float2(0.075))).toSrgbLinear();
  // return color;
  var left = Oklch({0.7, 0.12, 180 + 180*sin(t*0.5)});
  var right = Oklch({0.7, 0.12, 180*sin(t*0.8)});
  switch(case) {
    case 0: {
        float3 val = lerp(left.v, right.v, xy.x);
        color = Oklch(val).toOklab().toSrgbLinear();
        break;
    }
    case 1:  {
        float3 val = lerp(left.toOklab().v, right.toOklab().v, xy.x);
        color = Oklab(val).toSrgbLinear();
        break;
    }
    case 2: {
        float y = xy.x*10 - 4; 
        if(y != saturate(y)) discard;
        float3 val = lerp(left.v, right.v, y);
        color = Oklch(val).toOklab().toSrgbLinear();
        break;
    }
    case 3: {
        float y = xy.x*10 - 4; 
        if(y != saturate(y)) discard;
        float3 val = lerp(left.toOklab().v, right.toOklab().v, y);
        color = Oklab(val).toSrgbLinear();
      break;
    }
    default: discard;
  }
  if(!isRGB(color)) discard;
  return color;
}

SrgbLinear colorTest(float4 position, SceneInfo scene) {
  float  t      = scene.time;
  float2 win    = scene.window;
  float  scale  = exp(-scene.scale * 0.5 + 1);
  float  aspect = win.y / win.x;
  float2 offset = scale * scene.offset / win * float2(1, aspect);
  float2 xy     = scale * uv2math(position.xy / win, aspect) - offset;
  float2 mouse  = scale * uv2math(scene.mouse / win, aspect) - offset;
  float  px     = length(ddx(xy));
  SrgbLinear color;

  float len = length(xy);
  if(len >= 0.3) discard;

  color = Oklab({0.5 + 0.5*sin(t), xy.x, xy.y}).toSrgbLinear();
  if(any(color.v > 1.0) || any(color.v < 0.0)) color = Oklab({0.8, 0, 0}).toSrgbLinear();
  return color;
}

struct Scene : Sdf3d {
  float t;

  static var scene = repetition(Torus3d({0.3, 0.1}), float3(1)) + Sphere3d(0.8);

  [Differentiable]
  [ForceInline]
  float operator()(float3 p) {
    return scene(p);
  }
}

SrgbLinear pgaTest(float4 position, SceneInfo scene) {  
  float  t      = scene.time;
  float2 win    = scene.window;
  float  aspect = win.y / win.x;
  float2 xy     = uv2math(position.xy / win, aspect);
  float2 mouse  = uv2math(scene.mouse / win, aspect); //  - offset;
  float  px     = length(ddx(xy));
  float3 color;

  // if(xy.x < 0) {

  // var p = normalize(line(float3(rel_mouse.y, -rel_mouse.x, 0)));
  // var dist = length(join(p, point(xy))) - 10*px;
  // // color = shape(color, length(join(p, point(xy))) - 1*px, px, BorderedColor());
  // color = Oklab(iqColorize(10*dist)).toSrgbLinear().v;
  // } else {
  //   color = Oklab(iqColorize(10*(distance(rel_mouse, xy) - 10*px))).toSrgbLinear().v;
  // }
  var pmouse = point(mouse);
  var p = point(xy);

  var p1 = point({0, 0.1});
  var p2 = point({0, 0});
  // var p3 = point({0.5, 0});
  var l1 = join(p1, p2);
  var l2 = join(p2, pmouse);
  var l3 = join(pmouse, p1);

  var d1 = length(join(normalize(l1), p));
  var d2 = length(join(normalize(l2), p));
  var d3 = length(join(normalize(l3), p));

  var d = min(min(d1, d2), d3);

  color = Oklab(iqColorize(5*d - 5*px)).toSrgbLinear().v;
  return SrgbLinear(color);
}

float3 blinnPhong(float3 hitPos, float3 normal, float3 cameraPos, float3 lightPos, float hardness) {
  float3 cameraDir = normalize(cameraPos - hitPos);
  float3 lightDir  = normalize(lightPos  - hitPos);
  float3 half      = normalize(lightDir  + cameraDir);
  float  distsq    = dot(lightPos - hitPos, lightPos - hitPos);
  
  float  diffuseInt  = clamp(dot(normal, lightDir), 0.0, 1.0);
  float  specularInt = pow(clamp(dot(normal, half), 0.0, 1.0), hardness);
  return
      10 * diffuseInt  * Oklch({0.2318, 0.0476, 282}).toOklab().toSrgbLinear().v / distsq
    + 10 * specularInt * Oklch({0.85, 0, 0}).toOklab().toSrgbLinear().v / distsq
    + float3(0.01, 0.01, 0.02)
    ;
}

struct Ray {
  float3 origin;
  float3 direction;
}

struct RaymarchResult {
  float3 hitPos;
  float  distance;
  float3 normal    = {0, 0, 0};
  float  depth     = 1.0/0.0;
  int    steps     = 0;
  bool   exhausted = false;

  static const float HIT = 0.0001;
  bool isHit() {
    return abs(distance) <= HIT;
  }
};

struct RaymarchOptions {
  int   max_steps = 1000;
  float near      =   0.01;
  float far       =  10.0;
};

RaymarchResult raymarch(Ray ray, Sdf3d sdf, RaymarchOptions opts) {
  RaymarchResult res = {};
  res.hitPos = ray.origin;
  res.distance = sdf(res.hitPos);
  while( res.steps < opts.max_steps // opts.max_iter
      && distance(res.hitPos, ray.origin) < opts.far
      // && distance(res.hitPos, ray.origin) > opts.near
      && !res.isHit()
  ) {
    res.hitPos += ray.direction * res.distance;
    res.distance = sdf(res.hitPos);
    res.steps++;
  }
  if(res.isHit()) {
    res.normal = sdf.normal(res.hitPos);
    res.depth = distance(res.hitPos, ray.origin);
  }
  res.exhausted = res.steps == opts.max_steps;
  return res;
}

SrgbLinear raymarcher(float4 position, SceneInfo scene) {
  float  t      = scene.time;
  float2 win    = scene.window;
  float  aspect = win.y / win.x;
  float2 xy     = uv2math(position.xy / win, aspect);
  float3 color;

  static float3 BACKGROUND = float3(0.1);
  color = BACKGROUND;
  float3 up        = {0, 0, 1};
  float3 cameraPos = 3 * float3(cos(t), sin(t), 0.5);
  float3 cameraDir = normalize(-cameraPos); 
  float3 right     = normalize(cross(cameraDir, up));

  float3 lightPos  = float3(-3, -2, 1);
  
  float3 rayOrigin = cameraPos;
  float3 rayDirection = normalize(cameraDir + 2 * (right*xy.x + up*xy.y));
  var s = Scene(scene.time);
  float qs = 10.0;
  var quad = Quad3d({-qs, -qs, 0}, {-qs, qs, 0}, {qs, qs, 0}, {qs, -qs, 0});

  var ray = Ray(rayOrigin + rayDirection, rayDirection);

  var s_res    = raymarch(ray, s, {});
  var quad_res = RaymarchResult(); // raymarch(ray, quad, {});

  if(min(quad_res.depth, s_res.depth) >= 10) color = BACKGROUND;
  else {
    // if(quad_res.depth <= s_res.depth) {
    if(quad_res.depth <= s_res.depth && s(quad_res.hitPos) < 0.1) {
      var hp = quad_res.hitPos;
      // var dx = ddx(hp)*0.0;
      // var dy = ddy(hp)*0.0;
      // var val = (2 * s(hp) + s(hp + dx) + s(hp - dx) + s(hp + dy) + s(hp - dy)) / 6;
      // var val = s(hp);
      // val = min(min(val, abs(val + ddx(val))), abs(val + ddy(val)));
      color = Oklab(iqColorize(s(hp))).toSrgbLinear().v;
      // color = Oklab({0.8, xy.x, xy.y}).toSrgbLinear().v;
    } else {
      color = blinnPhong(s_res.hitPos, s_res.normal, rayOrigin, lightPos, 100.0);
      // if(s_res.exhausted) color = {1, 0.2, 0.2};
    }
  }
  // color.x += max(s_res.steps, quad_res.steps) / 20;

  return SrgbLinear(color);
}


SrgbLinear simpleSDFImage(float4 position, SceneInfo scene) {
  float   t         = scene.time;
  float   scale     = exp(-scene.scale * 0.5 + 1);
  float2  win       = scene.window;
  float   aspect    = win.y / win.x;
  float2  offset    = scale * scene.offset / win * float2(1, aspect);
  float2  xy        = scale * uv2math(position.xy / win, aspect) - offset;
  float2  rel_mouse = scale * uv2math(scene.mouse / win, aspect) - offset;
  float   px        = length(ddx(xy));
  complex p         = {xy.x, xy.y};
  float3 color = float3(1);

  float dist = sdRoundedBox2D(xy, {0.7, 0.5}, {0.1, 0.1, 0.2, 0.3 + 0.1*cos(t)});
  color = iqColorize(dist);

  return Oklab(color).toSrgbLinear();
}

// Inigo Quilez-style colorization of SDFs
// in Oklab color space
float3 iqColorize(float dist) {
  static float3 iq_blue = Oklch({0.87, 0.075, 240}).toOklab().v; 
  static float3 iq_orange = Oklch({0.75, 0.13, 63}).toOklab().v;
  float3 color = dist < 0.0 ? iq_blue : iq_orange;
  color.x *= 1.0 - exp2(-24.0*abs(dist));
  color.x *= 0.8 + 0.2 * cos(100.0 * abs(dist));
  return lerp(color, float3(1, 0, 0), 1.0 - smoothstep(0.0, 0.01, abs(dist)));
}

Oklab mandelbrotImage(float4 position, SceneInfo scene) {
  float2 win    = scene.window;
  float  scale  = exp(-scene.scale * 0.5);
  float  aspect = win.y / win.x;
  float2 offset = scale * scene.offset / win * float2(1, aspect);
  float2 xy     = scale * uv2math(position.xy / win, aspect) - offset;
  float2 mouse  = scale * uv2math(scene.mouse / win, aspect) - offset;
  float  px     = length(ddx(xy));
  complex s     = {xy.x, xy.y};
  float3 color;
  color = DomainColor(s).toOklab().v;

  complex res;
  // complex offs = {-0.2, -0.2};
  // complex MOVE = TAU * Im / (log(16) + TAU * Im);
  res = s;
  // res = (s.log() * MOVE).exp();
  // res = (s * s - 1) * (s - 2 - I) * (s - 2 - I) / (s * s + 2 + 2*I);
  // res = s.exp();
  // res = ((s.log() - offs) / MOVE + offs).exp();
  // res = (s.log() / MOVE).exp();
  // complex dfdx = ddx(res);
  complex dfdx = {ddx(res.r), ddx(res.i)};
  complex dfdy = {ddy(res.r), ddy(res.i)};
  float stretch = (dfdx.mag() + dfdy.mag()) * 0.5;
  
  int NUM_ITERS = 100;
  int i = 0;
  complex z = {0, 0};
  complex acc = z;
  complex c = res;
  for(; i <= NUM_ITERS; i++) {
    z = z * z + c; 
    acc = acc + z;
    if(z.magsq() > 4.0) break;
  }

  // exterior
  if(i < NUM_ITERS) {
    float3 dc = DomainColor(acc).toOklab().v; //   - float3(0.1, 0.05, 0);
    color = shape(color, -1, 0, Solid(dc));
  }

  float grid = sdGrid2D(xy, px);
  color = shape(color, grid, px, Solid(float3(0.1, 0, 0)));
  // color = iqColorize(grid);

  // interior
  if(i >= NUM_ITERS) {
    float perc = (float)i / (float)NUM_ITERS;
    float param = atan(perc);
    float3 dc = DomainColor(acc).toOklab().v - float3(0.4, 0, 0);
    color = shape(color, -1, 0, Solid(dc));
  }

  float2 pos = res.coord();
  complex c0 = {mouse.x, mouse.y};

  z = {0, 0};
  for(int j = 0; j < NUM_ITERS; j++) {
    complex zp = z * z + c0;
    float2 p = z.coord();
    float2 pp = zp.coord();
    color = shape(color, sdUnion(
      sdSegment2D(pos, p, pp) - px,
      sdCircle2D(pos, p, 6*px),
    ), px, BorderedColor(2*px));
    z = zp;
  }

  return Oklab(color);
}

interface IMaterial { float3 operator()(float dist, float px); }

struct BorderedColor: IMaterial {
  float border;
  float3 operator()(float dist, float px) {
    static float3 inner_color = Oklch({L, 0.3, 90}).toOklab().v;
    static float3 outer_color = Oklch({1, 0, 90}).toOklab().v;

    if(dist > px) return float3(0);
    else if(dist < -border-px) return inner_color;
    else return lerp(inner_color, outer_color, smoothstep(-border - px, -border + px, dist));
  }
};

struct Solid: IMaterial {
  float3 color;
  float3 operator()(float dist, float px) {
    return color;
  }
}

float3 shape<Mat: IMaterial>(float3 prev, float dist, float px, Mat mat) {
  float ps = px; //  * 0.5;
// #define SMOOTH 1
// #if SMOOTH
  if(isnan(dist)) return prev;
  if(dist > ps) return prev;
  float3 inner = mat(dist, px);
  if(dist < -ps) return inner;
  else return lerp(inner, prev, smoothstep(-ps, ps, dist));
// #else 
//   if(dist >= 0) return prev;
//   else return mat(dist, ps);
// #endif
}
