#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// Fluid-acrylic pour, for entering paint mode: marbled colour (domain-warped noise) that
// keeps flowing downward, poured out of the model selector with a dripping front, then
// drained away from the top. Palette after a real acrylic pour: deep and sky blues, lime,
// cream, coral, ink, with copper veins and white cells.

static float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

static float noise(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash21(i), hash21(i + float2(1, 0)), u.x),
               mix(hash21(i + float2(0, 1)), hash21(i + float2(1, 1)), u.x), u.y);
}

static float fbm(float2 p) {
    float v = 0.0, a = 0.5;
    const float2x2 m = float2x2(1.6, 1.2, -1.2, 1.6);
    for (int i = 0; i < 4; i++) { v += a * noise(p); p = m * p; a *= 0.5; }
    return v;
}

/// The marbled paint at `uv` (screen units, height = 1) at `time`.
static float3 marble(float2 uv, float time, thread float &depth) {
    // Sample from higher up as time passes: the pattern runs down the screen.
    float2 p = uv * 2.9 + float2(0.0, -time * 0.42);
    float2 q = float2(fbm(p + float2(0.0, time * 0.05)), fbm(p + float2(5.2, 1.3)));
    float2 r = float2(fbm(p + 3.6 * q + float2(1.7, 9.2) + time * 0.07), fbm(p + 3.6 * q + float2(8.3, 2.8)));
    float f = fbm(p + 3.2 * r);
    depth = f;

    const float3 navy   = float3(0.05, 0.07, 0.14);
    const float3 blue   = float3(0.07, 0.33, 0.88);
    const float3 sky    = float3(0.45, 0.76, 1.00);
    const float3 lime   = float3(0.67, 0.86, 0.20);
    const float3 cream  = float3(0.98, 0.93, 0.62);
    const float3 coral  = float3(0.97, 0.62, 0.54);
    const float3 copper = float3(0.78, 0.52, 0.25);

    // Crisp boundaries between colours, like paint that hasn't mixed.
    float3 col = mix(cream, coral, smoothstep(0.46, 0.54, q.x));
    col = mix(col, sky, smoothstep(0.45, 0.50, r.x));
    col = mix(col, blue, smoothstep(0.50, 0.55, f));
    col = mix(col, lime, smoothstep(0.62, 0.67, r.y) * (1.0 - smoothstep(0.52, 0.56, f)));
    // Deep navy pockets inside the blue.
    col = mix(col, navy, smoothstep(0.60, 0.66, f) * smoothstep(0.48, 0.56, r.x));
    // Thin copper veins folded through the paint, and finer white ones.
    float vein = 1.0 - smoothstep(0.0, 0.022, abs(fract(q.y * 5.0 + f * 3.0) - 0.5));
    col = mix(col, copper, vein * 0.95 * smoothstep(0.4, 0.55, r.y));
    float strand = 1.0 - smoothstep(0.0, 0.012, abs(fract(r.x * 7.0 + f * 4.0) - 0.5));
    col = mix(col, float3(1.0), strand * 0.6 * smoothstep(0.5, 0.56, f));
    // A soft wet sheen along the folds.
    col += 0.10 * pow(1.0 - abs(fract(f * 3.0) - 0.5) * 2.0, 12.0);

    // White cells riding in the blues, like bubbles in a pour.
    float2 cp = (uv + float2(0.0, -time * 0.18)) * 30.0 + r * 4.0;
    float2 ci = floor(cp), cf = fract(cp);
    float2 c = float2(hash21(ci + 3.1), hash21(ci + 7.7)) * 0.6 + 0.2;
    float radius = 0.07 + 0.22 * hash21(ci + 1.9);
    float cell = hash21(ci) > 0.7 ? 1.0 - smoothstep(radius - 0.05, radius, length(cf - c)) : 0.0;
    col = mix(col, float3(1.0), cell * 0.95 * smoothstep(0.48, 0.54, f));
    return col;
}

static float smin(float a, float b, float k) {
    float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
    return mix(b, a, h) - k * h * (1.0 - h);
}

/// `fill`: how far the pour has run down (0…1, past the bottom at 1).
/// `drain`: how far it has cleared from the top (0…1).
/// `origin`, `pill`: the selector's centre and size, in points. The paint wells up around
/// the pill (rounded like it), leaving the pill itself showing, and falls from there.
[[ stitchable ]] half4 acrylicPour(float2 position, half4 color, float2 size, float time, float fill, float drain, float2 origin, float2 pill) {
    float2 uv = position / size.y;
    float2 o = origin / size.y;
    float y = uv.y - o.y;       // below the pill's centre
    float x = uv.x - o.x;
    float2 half_pill = pill * 0.5 / size.y;
    float margin = 0.014;
    float aa = 1.5 / size.y;

    // A collar of paint round the pill, rounded the same way.
    float r = half_pill.y + margin;
    float collar = length(float2(max(abs(x) - (half_pill.x - half_pill.y), 0.0), y)) - r;
    // The fall: as wide as the collar where it leaves, swelling out to the screen's edges
    // over a short drop, like a thick pour spreading.
    float edge = size.x / size.y * 0.5 + 0.03;
    float t = clamp(y / 0.3, 0.0, 1.0);
    float width = (half_pill.x + margin) + (edge - half_pill.x) * t * t * (3.0 - 2.0 * t)
                + 0.012 * (fbm(float2(y * 9.0, time * 0.8)) - 0.5);
    float fall = max(abs(x) - width, -y);
    float shape = smin(collar, fall, 0.05);

    // The front drips: fingers of paint run ahead of the rest, growing as it falls.
    float fingers = fbm(float2(uv.x * 7.0, 1.3));
    float drips = (0.16 * pow(fingers, 2.0) + 0.05 * fbm(float2(uv.x * 18.0, time * 0.6))) * min(fill * 3.0, 1.0);
    float front = -half_pill.y - margin + fill * 1.35 + drips;
    float inside = smoothstep(aa, -aa, shape) * smoothstep(-aa, aa * 2.0, front - y);
    // Draining: the top edge runs down after it, ragged in the same way.
    float top = drain * 1.5 - 0.25 + drips * 0.7;
    inside *= drain > 0.0 ? smoothstep(0.0, aa * 2.0, y - top) : 1.0;
    // The pill itself stays clear: the paint comes out from round it.
    float hole = length(float2(max(abs(x) - (half_pill.x - half_pill.y), 0.0), y)) - half_pill.y;
    inside *= smoothstep(-aa, aa, hole);
    if (inside <= 0.0) { return half4(0.0); }

    float depth;
    float3 col = marble(uv, time, depth);
    // The leading edge sits a touch darker and glossier, like a wet lip.
    float lip = smoothstep(0.03, 0.0, front - y);
    col = mix(col, col * 0.8 + 0.12, lip * 0.6);
    return half4(half3(col * inside), half(inside));
}
