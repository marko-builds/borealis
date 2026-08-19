// Borealis — GPU-procedural aurora over water, ported from play/aurora.py
// via lookdev/index.html (the browser page holds the tuning history).
// Composition: curtains + stars + meteors + crescent moon + water + forested
// ridge. Five palettes baked as constants, selected by the paletteIndex
// uniform (single config surface, switches live).
#version 440

layout(location = 0) in vec2 qt_TexCoord0;   // y = 0 at top
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float time;
    vec2 resolution;
    float paletteIndex;   // 0 aurora, 1 ember, 2 gold, 3 nord, 4 ice
};

const float WATERLINE = 0.82;

// 6-stop ramps per palette (flattened [pal*6+i]), from play/aurora.py PALETTES
const float RP[30] = float[30](
  0.00, 0.12, 0.30, 0.55, 0.80, 1.00,
  0.00, 0.15, 0.35, 0.60, 0.82, 1.00,
  0.00, 0.15, 0.35, 0.60, 0.82, 1.00,
  0.00, 0.18, 0.40, 0.62, 0.82, 1.00,
  0.00, 0.15, 0.35, 0.60, 0.82, 1.00);
const vec3 RC[30] = vec3[30](
  vec3(150., 45.,180.)/255., vec3( 90.,110.,205.)/255., vec3( 35.,200.,200.)/255.,
  vec3( 30.,235.,130.)/255., vec3( 25.,180., 80.)/255., vec3(  8., 70., 35.)/255.,
  vec3(200., 40.,150.)/255., vec3(225., 60., 95.)/255., vec3(235., 75., 60.)/255.,
  vec3(240.,120., 40.)/255., vec3(180., 70., 22.)/255., vec3( 60., 20., 12.)/255.,
  vec3(120., 70., 20.)/255., vec3(180.,120., 35.)/255., vec3(225.,165., 55.)/255.,
  vec3(245.,205.,110.)/255., vec3(235.,175., 90.)/255., vec3( 60., 40., 14.)/255.,
  vec3(180.,142.,173.)/255., vec3(129.,161.,193.)/255., vec3(136.,192.,208.)/255.,
  vec3(143.,188.,187.)/255., vec3(163.,190.,140.)/255., vec3( 90.,110., 75.)/255.,
  vec3( 60., 90.,200.)/255., vec3( 60.,150.,230.)/255., vec3( 90.,210.,235.)/255.,
  vec3(160.,235.,240.)/255., vec3(130.,185.,160.)/255., vec3( 20., 45., 75.)/255.);
const vec3 SKYB[5] = vec3[5](
  vec3( 6., 8.,18.)/255., vec3(10., 6.,12.)/255., vec3(10., 8., 6.)/255.,
  vec3(12.,14.,18.)/255., vec3( 6., 9.,22.)/255.);
const vec3 SKYA[5] = vec3[5](
  vec3( 8.,10.,22.)/255., vec3(16., 8.,14.)/255., vec3(16.,12., 8.)/255.,
  vec3(20.,24.,34.)/255., vec3( 8.,14.,26.)/255.);

int pal() { return int(clamp(paletteIndex, 0.0, 4.0) + 0.5); }

// piecewise-linear ramp, aurora.py ramp()/np.interp (clamped both ends)
vec3 ramp(float p) {
  int b = pal() * 6;
  if (p <= RP[b]) return RC[b];
  for (int i = 1; i < 6; i++) {
    if (p <= RP[b + i]) {
      float f = (p - RP[b + i - 1]) / (RP[b + i] - RP[b + i - 1]);
      return mix(RC[b + i - 1], RC[b + i], f);
    }
  }
  return RC[b + 5];
}

float hash21(vec2 p) {
  p = fract(p * vec2(234.34, 435.345));
  p += dot(p, p + 34.23);
  return fract(p.x * p.y);
}

// breaks 8-bit banding on the dark gradients: +-0.5/255 of hash noise
vec3 dither(vec2 uv) {
  return vec3(hash21(uv * resolution) - 0.5) / 255.0;
}

// smooth 2D value noise — wind gusts on the water
float vnoise(vec2 p) {
  vec2 i = floor(p), f = fract(p);
  f = f * f * (3.0 - 2.0 * f);
  return mix(mix(hash21(i),                 hash21(i + vec2(1.0, 0.0)), f.x),
             mix(hash21(i + vec2(0.0, 1.0)), hash21(i + vec2(1.0, 1.0)), f.x), f.y);
}

// One curtain layer — aurora.py Sky.frame l. 259-287
vec3 curtain(vec2 uv, float t,
             float baseY, float len, float alpha,
             vec3 f, vec3 a, vec3 s, float rayF, float rayS) {
  float fx = uv.x;
  float top = baseY
    + a.x * sin(fx * f.x * 6.28318 + t * s.x)
    + a.y * sin(fx * f.y * 6.28318 + t * s.y)
    + a.z * sin(fx * f.z * 6.28318 + t * s.z);
  float rel = (uv.y - top) / len;
  float inside = step(0.0, rel) * step(rel, 1.0);
  float b = clamp(1.0 - rel, 0.0, 1.0) * clamp(rel / 0.04, 0.0, 1.0) * inside;
  float rays = 0.55
    + 0.30 * sin(fx * rayF + t * rayS)
    + 0.15 * sin(fx * rayF * 2.3 - t * rayS * 1.7);
  b *= pow(clamp(rays, 0.0, 1.0), 1.6);
  b *= 0.75 + 0.25 * sin(t * 0.6 + baseY * 9.0);
  return ramp(rel) * b * alpha;
}

// Meteors — gather form of aurora.py _draw_meteors; two co-prime slots
vec3 meteors(vec2 uv, float t, float aspect) {
  vec3 acc = vec3(0.0);
  vec3 warm = vec3(1.0, 0.969, 0.894);
  for (int i = 0; i < 2; i++) {
    float P = (i == 0) ? 19.0 : 31.0;
    float cyc = floor(t / P) + float(i) * 7.0;
    float h1 = fract(sin(cyc * 12.9898) * 43758.5453);
    float h2 = fract(sin(cyc * 78.2330) * 12543.1230);
    float h3 = fract(sin(cyc * 39.4250) * 65231.7700);
    float t0 = (0.15 + 0.50 * h1) * P;
    float dur = 0.9 + 0.5 * h2;
    float p = (t - floor(t / P) * P - t0) / dur;
    if (p < 0.0 || p > 1.0) continue;
    float env = sqrt(sin(3.14159 * p));
    float theta = (0.20 + 0.25 * h3) * 3.14159;   // capped ~81deg, no plumb lines
    float sx = (h2 > 0.5) ? 1.0 : -1.0;
    vec2 start = vec2((0.05 + 0.90 * fract(h1 * 7.31)) * aspect,
                      0.02 + 0.40 * fract(h3 * 5.17));
    float dist = (0.25 + 0.25 * h2) * aspect;
    vec2 dir = normalize(vec2(cos(theta) * sx, sin(theta)));
    vec2 head = start + dir * dist * p;
    float tail = (0.07 + 0.05 * h1) * aspect;
    vec2 q = vec2(uv.x * aspect, uv.y) - head;
    float along = dot(q, -dir);
    float perp = length(q + dir * along);
    float ta = clamp(along / tail, 0.0, 1.0);
    float streak = (along > 0.0) ? pow(1.0 - ta, 2.0) : 0.0;
    streak *= exp(-perp * perp / (2.0 * 0.0000022));
    float bloom = exp(-dot(q, q) / (2.0 * 0.0000045));
    acc += warm * (streak * 1.3 + bloom * 1.5) * env * (0.8 + 0.5 * h3);
  }
  return acc;
}

// Everything above the waterline; the water mirrors this whole stack.
vec3 upperScene(vec2 uv, float t) {
  float aspect = resolution.x / resolution.y;
  int P = pal();

  // sky gradient
  vec3 col = SKYB[P] + SKYA[P] * (1.0 - uv.y);

  // starfield (hash gather; ~14px cells, kept above 0.7 height)
  if (uv.y < 0.7) {
    vec2 g = uv * resolution / 14.0;
    vec2 cell = floor(g);
    float h = hash21(cell);
    if (h > 0.55) {
      vec2 pos = vec2(hash21(cell + 7.3), hash21(cell + 3.1));
      float d = length((fract(g) - pos) * 14.0);
      float mag = 0.3 + 0.7 * hash21(cell + 11.7);
      float twk = 0.55 + 0.45 * sin(t * (1.5 + 2.5 * hash21(cell + 5.2))
                                    + 6.28318 * hash21(cell + 9.4));
      col += smoothstep(1.2, 0.0, d) * mag * twk * 0.78 * vec3(0.85, 0.9, 1.0);
    }
  }

  // crescent moon: pale disc minus offset disc, gentle halo; occludes stars
  {
    vec2 mp = (uv - vec2(0.78, 0.16)) * vec2(aspect, 1.0);
    float r = 0.055;
    float d1 = length(mp);
    float d2 = length(mp - vec2(0.020, -0.009));
    float crescent = clamp(smoothstep(r, r - 0.004, d1)
                         - smoothstep(r * 1.04, r * 1.04 - 0.004, d2), 0.0, 1.0);
    vec3 moonCol = vec3(0.95, 0.93, 0.85);
    col = mix(col, moonCol, crescent);
    col += moonCol * exp(-d1 * 34.0) * 0.10;
  }

  // three curtain layers, aurora.py self.layers
  col += curtain(uv, t, 0.18, 0.55, 1.00,
                 vec3(1.3, 2.7, 5.1), vec3(0.05, 0.03, 0.015),
                 vec3(0.21, -0.13, 0.31), 23.0, 0.7);
  col += curtain(uv, t, 0.30, 0.42, 0.75,
                 vec3(0.9, 2.1, 4.3), vec3(0.06, 0.035, 0.02),
                 vec3(-0.15, 0.19, -0.27), 17.0, -0.5);
  col += curtain(uv, t, 0.42, 0.32, 0.55,
                 vec3(1.7, 3.3, 6.5), vec3(0.04, 0.025, 0.012),
                 vec3(0.11, -0.23, 0.17), 31.0, 0.9);

  // meteors streak over the curtains
  col += meteors(uv, t, aspect);

  // forested ridge standing on the waterline
  float fx = uv.x;
  float ridge = 0.5
    + 0.30 * sin(fx * 3.1 + 0.6)
    + 0.12 * sin(fx * 7.7 + 2.0)
    + 0.06 * sin(fx * 15.3 + 4.1);
  ridge /= 0.98;
  float ridgeTop = WATERLINE - ridge * 0.20;

  float tw = 170.0;
  float cell = floor(fx * tw);
  float hcell = hash21(vec2(cell, 3.7));
  float th = (hcell < 0.12) ? 0.0 : 0.005 + 0.011 * hcell;
  float spike = 1.0 - abs(fract(fx * tw) * 2.0 - 1.0);
  float silTop = ridgeTop - th * spike;

  float px = 1.5 / resolution.y;
  float m = smoothstep(silTop - px, silTop + px, uv.y);
  if (m > 0.0) {
    float into = clamp((uv.y - ridgeTop) / max(1.0 - ridgeTop, 0.001), 0.0, 1.0);
    vec3 mtn = mix(vec3(11.0, 14.0, 24.0), vec3(4.0, 5.0, 9.0),
                   clamp(into * 1.7, 0.0, 1.0)) / 255.0;
    mtn += vec3(0.030, 0.045, 0.060) * exp(-into * 50.0);
    col = mix(col, mtn, m);
  }

  return col;
}

void main() {
  vec2 uv = qt_TexCoord0;
  float t = time;
  vec3 col;

  if (uv.y >= WATERLINE) {
    // water: stretched mirror of the upper scene, rippled, gust-blurred,
    // shimmer-broken, darkening with depth
    float depth = (uv.y - WATERLINE) / (1.0 - WATERLINE);
    float K = 3.2;
    vec2 ruv = vec2(uv.x, WATERLINE - (uv.y - WATERLINE) * K);
    ruv.x += (0.0015 + 0.004 * depth)
             * sin(uv.y * 34.0 + t * 1.4)
             * sin(uv.y * 11.0 - t * 0.9);
    ruv.y += 0.004 * depth * sin(uv.x * 18.0 + uv.y * 26.0 + t * 0.8);
    ruv = clamp(ruv, 0.0, 1.0);

    // 5 taps at tight spacing (sparse wide taps ghost thin features);
    // gusts scale the spacing mildly
    float gust = vnoise(vec2(uv.x * 6.0 - t * 0.18, uv.y * 3.0 + t * 0.06));
    float s = (0.003 + 0.005 * depth) * (0.7 + 0.6 * gust);
    vec3 refl = upperScene(ruv, t) * 0.30
              + upperScene(vec2(ruv.x, clamp(ruv.y - s, 0.0, 1.0)), t) * 0.22
              + upperScene(vec2(ruv.x, clamp(ruv.y + s, 0.0, 1.0)), t) * 0.22
              + upperScene(vec2(ruv.x, clamp(ruv.y - 2.0 * s, 0.0, 1.0)), t) * 0.13
              + upperScene(vec2(ruv.x, clamp(ruv.y + 2.0 * s, 0.0, 1.0)), t) * 0.13;

    float cx = uv.x * 48.0;
    float ci = floor(cx);
    float cf = fract(cx); cf = cf * cf * (3.0 - 2.0 * cf);
    float colPhase = 3.5 * mix(hash21(vec2(ci, 0.0)), hash21(vec2(ci + 1.0, 0.0)), cf);
    float shimmer = 0.86 + 0.14 * sin(uv.y * 38.0 + colPhase + t * 1.8);
    shimmer *= 0.94 + 0.06 * sin(uv.y * 9.0 - t * 1.1 + colPhase * 0.7);

    col = refl * shimmer * (0.62 - 0.34 * depth) + vec3(0.010, 0.018, 0.038);
    col += vec3(0.05, 0.08, 0.10) * smoothstep(0.015, 0.0, uv.y - WATERLINE);
  } else {
    col = upperScene(uv, t);
  }

  fragColor = vec4(clamp(col + dither(uv), 0.0, 1.0), 1.0) * qt_Opacity;
}
