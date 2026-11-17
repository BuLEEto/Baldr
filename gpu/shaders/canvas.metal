// canvas.metal — the Metal port of the canvas passes: blend.frag,
// transform.frag, filter.frag, dab.vert/frag and stroke.vert/frag, plus the
// two small passes Vulkan gets from its API rather than a shader (a fill
// over a sub-rectangle, and a copy that converts between formats).
//
// Ported character for character from the GLSL, not paraphrased. Every
// formula here has its twin in baldr/canvas_blend.odin, canvas_transform.odin,
// canvas_filter.odin, canvas_brush.odin and canvas_stroke.odin — the CPU
// references the parity spikes check both backends against. Change one,
// change all three.
//
// Three things differ from the GLSL by necessity, and nothing else does:
//
//  * **NDC y.** Metal's clip space has y up where Vulkan's has y down, so the
//    dab and stroke vertex shaders flip it: a texel at y = 0 is the top row
//    in both. The full-screen triangle needs no flip — it covers all of NDC
//    either way — and a fragment's `[[position]]` is framebuffer coords with
//    a top-left origin in both, so it is `gl_FragCoord` unchanged.
//
//  * **`packed_` vertex types.** Odin aligns `[4]f32` to 4, MSL aligns
//    `float4` to 16. `Stroke_Vertex` puts its `seg` at offset 8, where a
//    plain `float4` would sit at 16 and every stroke would be drawn from
//    the wrong numbers. The push constants are *not* packed: those structs
//    are laid out for a vec4-aligned uniform block already, and
//    `Transform_Push`'s three vec4-aligned columns are exactly `float3x3`.
//
//  * **Push constants are a buffer.** `layout(push_constant)` becomes
//    `constant X& pc [[buffer(0)]]`, set with `setFragmentBytes`.
//
// Vertex buffers are read as `device const T*` indexed by `vertex_id` rather
// than through a MTLVertexDescriptor: the layout is already the struct's, so
// describing it twice only adds somewhere for the two to disagree.

#include <metal_stdlib>
using namespace metal;

// ----------------------------------------------------- the full-screen pass

struct FS_Out {
    float4 position [[position]];
};

// One triangle covering the viewport, from the vertex id alone: (-1,-1),
// (3,-1), (-1,3). The scissor rectangle is what confines it to the op's
// rectangle, exactly as on Vulkan.
vertex FS_Out canvas_fs(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    FS_Out o;
    o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    return o;
}

// ------------------------------------------------------------- blend maths
//
// blend_common.glsl, unchanged. curves: 0 sRGB's (sRGB, Display P3),
// 1 Adobe RGB's 2.2, 2 linear.

static inline float decode1(float c, uint curve) {
    if (curve == 2u) return c;
    if (curve == 1u) return pow(max(c, 0.0), 2.19921875);
    return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4);
}
static inline float encode1(float c, uint curve) {
    if (curve == 2u) return c;
    if (curve == 1u) return pow(max(c, 0.0), 1.0 / 2.19921875);
    return c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1.0 / 2.4) - 0.055;
}
static inline float3 decode3(float3 c, uint curve) { return float3(decode1(c.r, curve), decode1(c.g, curve), decode1(c.b, curve)); }
static inline float3 encode3(float3 c, uint curve) { return float3(encode1(c.r, curve), encode1(c.g, curve), encode1(c.b, curve)); }

static inline float lum(float3 c) { return 0.3 * c.r + 0.59 * c.g + 0.11 * c.b; }
static inline float3 clip_color(float3 c) {
    float l = lum(c);
    float n = min(min(c.r, c.g), c.b);
    float x = max(max(c.r, c.g), c.b);
    if (n < 0.0) c = l + (c - l) * l / (l - n);
    if (x > 1.0) c = l + (c - l) * (1.0 - l) / (x - l);
    return c;
}
static inline float3 set_lum(float3 c, float l) { return clip_color(c + (l - lum(c))); }
static inline float sat(float3 c) { return max(max(c.r, c.g), c.b) - min(min(c.r, c.g), c.b); }
static inline float3 set_sat(float3 c, float s) {
    float mx = max(max(c.r, c.g), c.b);
    float mn = min(min(c.r, c.g), c.b);
    return mx > mn ? (c - mn) * s / (mx - mn) : float3(0.0);
}

static inline float burn(float b, float s)  { return b >= 1.0 ? 1.0 : (s <= 0.0 ? 0.0 : 1.0 - min(1.0, (1.0 - b) / s)); }
static inline float dodge(float b, float s) { return b <= 0.0 ? 0.0 : (s >= 1.0 ? 1.0 : min(1.0, b / (1.0 - s))); }
static inline float soft_d(float b)         { return b <= 0.25 ? ((16.0 * b - 12.0) * b + 4.0) * b : sqrt(b); }

static inline float sep(uint mode, float b, float s) {
    switch (mode) {
    case 2u:  return min(b, s);                                                    // darken
    case 3u:  return b * s;                                                        // multiply
    case 4u:  return burn(b, s);                                                   // colour burn
    case 5u:  return max(b + s - 1.0, 0.0);                                        // linear burn
    case 7u:  return max(b, s);                                                    // lighten
    case 8u:  return b + s - b * s;                                                // screen
    case 9u:  return dodge(b, s);                                                  // colour dodge
    case 10u: return min(b + s, 1.0);                                              // linear dodge (add)
    case 12u: return b <= 0.5 ? 2.0 * b * s : 1.0 - 2.0 * (1.0 - b) * (1.0 - s);   // overlay
    case 13u: return s <= 0.5 ? b - (1.0 - 2.0 * s) * b * (1.0 - b) : b + (2.0 * s - 1.0) * (soft_d(b) - b); // soft light
    case 14u: return s <= 0.5 ? 2.0 * b * s : 1.0 - 2.0 * (1.0 - b) * (1.0 - s);   // hard light
    case 15u: return s <= 0.5 ? burn(b, 2.0 * s) : dodge(b, 2.0 * (s - 0.5));      // vivid light
    case 16u: return clamp(b + 2.0 * s - 1.0, 0.0, 1.0);                           // linear light
    case 17u: return s <= 0.5 ? min(b, 2.0 * s) : max(b, 2.0 * s - 1.0);           // pin light
    case 18u: return b + s >= 1.0 ? 1.0 : 0.0;                                     // hard mix
    case 19u: return abs(b - s);                                                   // difference
    case 20u: return b + s - 2.0 * b * s;                                          // exclusion
    case 21u: return max(b - s, 0.0);                                              // subtract
    case 22u: return s <= 0.0 ? (b > 0.0 ? 1.0 : 0.0) : min(b / s, 1.0);           // divide
    }
    return s;                                                                      // normal, dissolve
}

static inline float3 blend(uint mode, float3 b, float3 s) {
    switch (mode) {
    case 6u:  return s.r + s.g + s.b < b.r + b.g + b.b ? s : b;                   // darker colour
    case 11u: return s.r + s.g + s.b > b.r + b.g + b.b ? s : b;                   // lighter colour
    case 23u: return set_lum(set_sat(s, sat(b)), lum(b));                         // hue
    case 24u: return set_lum(set_sat(b, sat(s)), lum(b));                         // saturation
    case 25u: return set_lum(s, lum(b));                                          // colour
    case 26u: return set_lum(b, lum(s));                                          // luminosity
    }
    return float3(sep(mode, b.r, s.r), sep(mode, b.g, s.g), sep(mode, b.b, s.b));
}

static inline uint pcg_hash(uint v) { // PCG
    uint state = v * 747796405u + 2891336453u;
    uint word  = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}

// --------------------------------------------------------------- the blend
//
// blend.frag: a source canvas composited onto a destination with one of
// Photoshop's 27 modes, an opacity and a mask, drawn over a copy of what was
// there (the backdrop).

struct Blend_Push {
    int2   src_off;
    int2   back_off;
    int2   mask_off;
    uint   mode;
    uint   flags;
    float  opacity;
    uint   seed;
    uint   pad0, pad1;
    float4 color;
};

fragment float4 blend_main(FS_Out in [[stage_in]],
                           constant Blend_Push& pc  [[buffer(0)]],
                           texture2d<float> src_tex  [[texture(0)]],
                           texture2d<float> back_tex [[texture(1)]],
                           texture2d<float> mask_tex [[texture(2)]]) {
    int2   p   = int2(in.position.xy);
    float4 src = (pc.flags & 64u) != 0u ? pc.color : src_tex.read(uint2(p + pc.src_off), 0);
    float4 dst = back_tex.read(uint2(p + pc.back_off), 0);
    float  m   = (pc.flags & 2u) != 0u ? mask_tex.read(uint2(p + pc.mask_off), 0).r : 1.0;
    float  as  = clamp(src.a * pc.opacity * m, 0.0, 1.0);
    float  ab  = clamp(dst.a, 0.0, 1.0);
    if (pc.mode == 1u) { // dissolve: the source's alpha becomes the chance of a whole pixel
        float rnd = float(pcg_hash(uint(p.x) * 1973u + uint(p.y) * 9277u + pc.seed) >> 8u) / 16777216.0;
        as = rnd < as ? 1.0 : 0.0;
    }
    if ((pc.flags & 128u) != 0u) { // erase: the backdrop's alpha taken away by the source's
        return float4(dst.rgb, ab * (1.0 - as));
    }
    bool lin = (pc.flags & 1u) != 0u;
    uint dcurve = (pc.flags >> 2u) & 3u;
    uint scurve = (pc.flags >> 4u) & 3u;
    float3 cb = lin ? decode3(dst.rgb, dcurve) : dst.rgb;
    float3 cs = lin ? decode3(src.rgb, scurve) : src.rgb;
    float3 mixed = (1.0 - ab) * cs + ab * blend(pc.mode, cb, cs);
    float  ao = as + ab * (1.0 - as);
    float3 co = ao > 0.0 ? (as * mixed + ab * (1.0 - as) * cb) / ao : float3(0.0);
    if (lin) co = encode3(co, dcurve);
    return float4(co, ao);
}

// ----------------------------------------------------------- the transform
//
// transform.frag: a source canvas drawn into another through a 3×3 matrix,
// resampled, then laid on exactly as blend_main lays a source on.
//
// `inv` is a float3x3 because Odin's `[3][4]f32` *is* three vec4-aligned
// columns: the two layouts agree byte for byte.

struct Transform_Push {
    float3x3 inv;
    int2     back_off;
    int2     mask_off;
    int4     src_rect;
    uint     mode;
    uint     flags;
    uint     kern;      // `kernel` is an MSL keyword (the compute qualifier)
    float    opacity;
};

// TRANSFORM_MAX_TAPS bounds the gather in each direction, as the reference
// does: past this the kernel keeps its width but steps through it.
constexpr constant int TRANSFORM_MAX_TAPS = 16;

static inline float kernel_weight(uint f, float t) {
    float x = abs(t);
    if (f == 0u) return x <= 0.5 ? 1.0 : 0.0;                       // nearest
    if (f == 1u) return max(1.0 - x, 0.0);                          // bilinear
    if (f == 2u) {                                                  // Catmull-Rom
        if (x < 1.0) return 1.5 * x * x * x - 2.5 * x * x + 1.0;
        if (x < 2.0) return -0.5 * x * x * x + 2.5 * x * x - 4.0 * x + 2.0;
        return 0.0;
    }
    if (x < 1e-6) return 1.0;                                       // Lanczos3
    if (x >= 3.0) return 0.0;
    float pix = 3.14159265358979 * x;
    return 3.0 * sin(pix) * sin(pix / 3.0) / (pix * pix);
}

static inline float kernel_radius(uint f) {
    if (f == 0u) return 0.5;
    if (f == 1u) return 1.0;
    if (f == 2u) return 2.0;
    return 3.0;
}

static inline float2 map_point(float3x3 m, float2 p) {
    float3 v = m * float3(p, 1.0);
    return abs(v.z) > 1e-9 ? v.xy / v.z : v.xy;
}

fragment float4 transform_main(FS_Out in [[stage_in]],
                               constant Transform_Push& pc [[buffer(0)]],
                               texture2d<float> src_tex  [[texture(0)]],
                               texture2d<float> back_tex [[texture(1)]],
                               texture2d<float> mask_tex [[texture(2)]]) {
    int2   p = int2(in.position.xy);
    float2 c = map_point(pc.inv, in.position.xy);

    // how much source one destination texel covers, per axis: the lengths of
    // the inverse's columns, never less than one texel
    // …except for nearest, which is chosen because it takes one texel whole
    float2 scale = pc.kern == 0u ? float2(1.0)
                 : float2(max(length(float2(pc.inv[0][0], pc.inv[0][1])), 1.0),
                          max(length(float2(pc.inv[1][0], pc.inv[1][1])), 1.0));
    float  reach = kernel_radius(pc.kern);
    float2 r     = reach * scale;
    // named `stride`, not `step`: `step` is an MSL builtin and shadowing it
    // here would be legal and confusing
    float2 stride = max(2.0 * r / float(TRANSFORM_MAX_TAPS), float2(1.0));

    float4 sum    = float4(0.0);
    float  weight = 0.0;
    float  full   = 0.0;
    if (pc.kern == 0u) { // one texel, whole: no kernel to run
        int2 s = int2(floor(c));
        if (s.x >= pc.src_rect.x && s.y >= pc.src_rect.y &&
            s.x < pc.src_rect.x + pc.src_rect.z && s.y < pc.src_rect.y + pc.src_rect.w) {
            float4 t = src_tex.read(uint2(s), 0);
            sum = float4(t.rgb * t.a, t.a); // premultiplied, as the gather is
            weight = 1.0;
        }
        full = 1.0;
    } else {
    // Counted, not accumulated: a loop whose end is a float comparison can
    // run away on a GPU (one NaN in the matrix and the device is lost), and
    // the count is what the reference walks too.
    int2   taps = int2(clamp(ceil(2.0 * r / stride), float2(1.0), float2(float(TRANSFORM_MAX_TAPS))));
    float2 u0   = floor((c - r) / stride) * stride + stride * 0.5;
    for (int i = 0; i < taps.x; i++) {
        float u = u0.x + float(i) * stride.x;
        float wx = kernel_weight(pc.kern, (u - c.x) / scale.x);
        if (wx == 0.0) continue;
        for (int j = 0; j < taps.y; j++) {
            float v = u0.y + float(j) * stride.y;
            float k = wx * kernel_weight(pc.kern, (v - c.y) / scale.y);
            if (k == 0.0) continue;
            full += k;
            int2 s = int2(floor(u), floor(v));
            if (s.x < pc.src_rect.x || s.y < pc.src_rect.y ||
                s.x >= pc.src_rect.x + pc.src_rect.z || s.y >= pc.src_rect.y + pc.src_rect.w) continue;
            // Premultiplied, always: averaging straight colours lets a clear
            // neighbour — black with zero alpha — pull the colour towards
            // black, and a transparent layer grows a dark fringe when it is
            // scaled or rotated.
            float4 t = src_tex.read(uint2(s), 0);
            sum += float4(t.rgb * t.a, t.a) * k;
            weight += k;
        }
    }
    }
    float4 dst = back_tex.read(uint2(p + pc.back_off), 0);
    if (weight <= 0.0) { // nothing of the source reaches here: the backdrop stands
        return dst;
    }
    // The colour comes back out of the premultiplied sum; partial coverage
    // of the source rectangle fades the edge.
    float4 src = float4(sum.a > 1e-6 ? sum.rgb / sum.a : float3(0.0),
                        max(sum.a / weight, 0.0) * clamp(weight / max(full, 1e-6), 0.0, 1.0));

    float m  = (pc.flags & 2u) != 0u ? mask_tex.read(uint2(p + pc.mask_off), 0).r : 1.0;
    float as = clamp(src.a * pc.opacity * m, 0.0, 1.0);
    float ab = clamp(dst.a, 0.0, 1.0);
    bool lin = (pc.flags & 1u) != 0u;
    uint dcurve = (pc.flags >> 2u) & 3u;
    uint scurve = (pc.flags >> 4u) & 3u;
    float3 cb = lin ? decode3(dst.rgb, dcurve) : dst.rgb;
    float3 cs = lin ? decode3(src.rgb, scurve) : src.rgb;
    float3 mixed = (1.0 - ab) * cs + ab * blend(pc.mode, cb, cs);
    float  ao = as + ab * (1.0 - as);
    float3 co = ao > 0.0 ? (as * mixed + ab * (1.0 - as) * cb) / ao : float3(0.0);
    if (lin) co = encode3(co, dcurve);
    return float4(co, ao);
}

// -------------------------------------------------------------- the filter
//
// filter.frag: a colour matrix, per-channel curves, a conversion between
// colour spaces, an app's 3D LUT, and a Gaussian blur (two passes) with an
// unsharp mask on its second.

struct Filter_Push {
    int2   in_off;
    int2   in_max;
    int2   aux_off;
    uint   kind;
    uint   flags;
    float  a;
    float  b;
    float  c;
    uint   pad;
    float4 m0, m1, m2, m3;
    float4 moff;
};

static inline float4 fetch_in(texture2d<float> in_tex, constant Filter_Push& pc, int2 t) {
    return in_tex.read(uint2(clamp(t, int2(0), pc.in_max)), 0);
}

static inline float curve1(texture2d<float> aux_tex, float v, int ch) {
    int   n = int(aux_tex.get_width(0));
    float x = clamp(v, 0.0, 1.0) * float(n - 1);
    int   i = min(int(floor(x)), n - 2);
    float t = x - float(i);
    return mix(aux_tex.read(uint2(i, 0), 0)[ch], aux_tex.read(uint2(i + 1, 0), 0)[ch], t);
}

// size n: n × n slices side by side, red across a slice, green down, blue by slice
static inline float3 lut3(texture2d<float> aux_tex, float3 v) {
    int    n = int(aux_tex.get_height(0));
    float3 x = clamp(v, 0.0, 1.0) * float(n - 1);
    int3   i = min(int3(floor(x)), int3(n - 2));
    float3 t = x - float3(i);
    float3 r = float3(0.0);
    for (int k = 0; k < 8; k++) {
        int3  o = int3(k & 1, (k >> 1) & 1, (k >> 2) & 1);
        float w = (o.x == 1 ? t.x : 1.0 - t.x) * (o.y == 1 ? t.y : 1.0 - t.y) * (o.z == 1 ? t.z : 1.0 - t.z);
        int3  p = i + o;
        r += w * aux_tex.read(uint2(p.x + p.z * n, p.y), 0).rgb;
    }
    return r;
}

// blur taps: sigma's Gaussian out to three sigmas, weights normalised
static inline float4 gauss(texture2d<float> in_tex, constant Filter_Push& pc,
                           int2 p, int2 dir, bool first, uint curve, bool lin) {
    float s = max(pc.a, 0.01);
    int   r = int(ceil(3.0 * s));
    float4 sum = float4(0.0);
    float  wsum = 0.0;
    for (int d = -r; d <= r; d++) {
        float  w = exp(-float(d * d) / (2.0 * s * s));
        float4 v = fetch_in(in_tex, pc, p + pc.in_off + dir * d);
        if (first) { // straight → premultiplied (and to light, in linear maths)
            if (lin) v.rgb = decode3(v.rgb, curve);
            v.rgb *= v.a;
        }
        sum += w * v;
        wsum += w;
    }
    return sum / wsum;
}

fragment float4 filter_main(FS_Out in [[stage_in]],
                            constant Filter_Push& pc [[buffer(0)]],
                            texture2d<float> in_tex  [[texture(0)]],
                            texture2d<float> aux_tex [[texture(1)]]) {
    int2 p = int2(in.position.xy);
    bool lin = (pc.flags & 1u) != 0u;
    uint icurve = (pc.flags >> 2u) & 3u;
    uint ocurve = (pc.flags >> 4u) & 3u;
    if (pc.kind == 4u) { // across: premultiplied, into the float intermediate
        return gauss(in_tex, pc, p, int2(1, 0), true, icurve, lin);
    }
    if (pc.kind == 5u || pc.kind == 6u) { // down, then straight again
        float4 v = gauss(in_tex, pc, p, int2(0, 1), false, icurve, lin);
        float3 c = v.a > 0.0 ? v.rgb / v.a : float3(0.0);
        if (pc.kind == 6u) { // unsharp: the original pushed away from its blur where they differ enough
            float4 o = aux_tex.read(uint2(p + pc.aux_off), 0);
            float3 oc = lin ? decode3(o.rgb, icurve) : o.rgb;
            float3 d = oc - c;
            float3 sharp = oc + pc.b * d;
            c = float3(abs(d.r) >= pc.c ? sharp.r : oc.r, abs(d.g) >= pc.c ? sharp.g : oc.g, abs(d.b) >= pc.c ? sharp.b : oc.b);
            v.a = o.a;
        }
        if (lin) c = encode3(c, ocurve);
        return float4(c, v.a);
    }
    float4 v = fetch_in(in_tex, pc, p + pc.in_off);
    if (pc.kind == 2u) { // convert: the input's space to the output's
        float3 l = decode3(v.rgb, icurve);
        l = float3(dot(pc.m0.rgb, l), dot(pc.m1.rgb, l), dot(pc.m2.rgb, l));
        return float4(encode3(l, ocurve), v.a);
    }
    if (lin) v.rgb = decode3(v.rgb, icurve);
    if (pc.kind == 0u) {
        v = float4(dot(pc.m0, v), dot(pc.m1, v), dot(pc.m2, v), dot(pc.m3, v)) + pc.moff;
    } else if (pc.kind == 1u) {
        v = float4(curve1(aux_tex, v.r, 0), curve1(aux_tex, v.g, 1), curve1(aux_tex, v.b, 2), curve1(aux_tex, v.a, 3));
    } else if (pc.kind == 3u) {
        v.rgb = lut3(aux_tex, v.rgb);
    }
    if (lin) v.rgb = encode3(v.rgb, ocurve);
    return v;
}

// ----------------------------------------------------------------- the dab
//
// dab.vert/frag: one quad per dab over the part of the stroke canvas it can
// touch. The pipeline's blending (ONE, ONE_MINUS_SRC_ALPHA) lays each over
// what is there: coverage = old + dab × (1 − old), dab after dab in order.

struct Dab_Push {
    float2 size;
    uint   tip;
    uint   pad;
};

struct Dab_Vertex {
    packed_float2 pos;    // texel coords of this corner
    packed_float2 centre; // the dab's centre
    packed_float4 dab;    // radius, hardness, strength, angle
};

struct Dab_Out {
    float4 position [[position]];
    float2 centre   [[flat]];
    float4 dab      [[flat]];
};

vertex Dab_Out dab_vert(uint vid [[vertex_id]],
                        device const Dab_Vertex* verts [[buffer(0)]],
                        constant Dab_Push& pc [[buffer(1)]]) {
    Dab_Vertex v = verts[vid];
    Dab_Out o;
    float2 p = float2(v.pos);
    // y flipped against the GLSL: Metal's clip space has y up, so a texel at
    // y = 0 must land at NDC +1 to be the top row
    o.position = float4(p.x / pc.size.x * 2.0 - 1.0, 1.0 - p.y / pc.size.y * 2.0, 0.0, 1.0);
    o.centre = float2(v.centre);
    o.dab = float4(v.dab);
    return o;
}

// Round tips: solid out to hardness × radius, then a smooth falloff to the
// rim (a hard tip is anti-aliased over a texel). A tip texture: its first
// channel, the dab's square turned by its angle.
fragment float4 dab_frag(Dab_Out in [[stage_in]],
                         constant Dab_Push& pc [[buffer(0)]],
                         texture2d<float> tip_tex [[texture(0)]],
                         sampler smp [[sampler(0)]]) {
    float  r = in.dab.x;
    float  hard = clamp(in.dab.y, 0.0, 1.0);
    float2 d = in.position.xy - in.centre;
    float  cov;
    if (pc.tip != 0u) {
        float  cs = cos(in.dab.w), sn = sin(in.dab.w);
        float2 q = float2(cs * d.x + sn * d.y, -sn * d.x + cs * d.y) / (2.0 * r) + 0.5;
        cov = (q.x < 0.0 || q.y < 0.0 || q.x > 1.0 || q.y > 1.0) ? 0.0 : tip_tex.sample(smp, q, level(0)).r;
    } else {
        float dist = length(d);
        if (hard >= 1.0) {
            cov = clamp(r - dist + 0.5, 0.0, 1.0);
        } else {
            float inner = hard * r;
            float t = clamp((dist - inner) / max(r - inner, 1e-4), 0.0, 1.0);
            cov = 1.0 - t * t * (3.0 - 2.0 * t);
        }
    }
    return float4(clamp(cov * in.dab.z, 0.0, 1.0));
}

// -------------------------------------------------------------- the stroke
//
// stroke.vert/frag: one quad per segment. The pipeline's MAX blending makes
// a stroke's segments a union rather than a build-up, so joins and
// self-crossings do not darken.

struct Stroke_Push {
    float2 size;
};

// `seg` sits at offset 8, which is why these are packed: a plain float4
// would be aligned to 16 and every segment would be read from the wrong
// bytes.
struct Stroke_Vertex {
    packed_float2 pos;   // texel coords of this corner
    packed_float4 seg;   // the segment: a.xy, b.xy
    packed_float2 radii; // its radius at each end
};

struct Stroke_Out {
    float4 position [[position]];
    float4 seg      [[flat]];
    float2 radii    [[flat]];
};

vertex Stroke_Out stroke_vert(uint vid [[vertex_id]],
                              device const Stroke_Vertex* verts [[buffer(0)]],
                              constant Stroke_Push& pc [[buffer(1)]]) {
    Stroke_Vertex v = verts[vid];
    Stroke_Out o;
    float2 p = float2(v.pos);
    o.position = float4(p.x / pc.size.x * 2.0 - 1.0, 1.0 - p.y / pc.size.y * 2.0, 0.0, 1.0);
    o.seg = float4(v.seg);
    o.radii = float2(v.radii);
    return o;
}

static inline float dot2(float2 v) { return dot(v, v); }

// A segment of a variable-width stroke is a **round cone** — two circles and
// their outer tangents — not a capsule: where the width changes the edge
// slopes, and a capsule leaves a step at every point of a tapering stroke.
// The three cases are the two end caps and the tangent between them.
static inline float round_cone(float2 p, float2 a, float2 b, float ra, float rb) {
    float2 ba = b - a;
    float  l2 = dot2(ba);
    float  rr = ra - rb;
    if (l2 <= 1e-12) return length(p - a) - max(ra, rb); // both ends one point: a disc
    float  a2 = l2 - rr * rr;
    float  il2 = 1.0 / l2;
    float2 pa = p - a;
    float  y = dot(pa, ba);
    float  z = y - l2;
    float  x2 = dot2(pa * l2 - ba * y);
    float  y2 = y * y * l2;
    float  z2 = z * z * l2;
    float  k = sign(rr) * rr * rr * x2;
    if (sign(z) * a2 * z2 > k) return sqrt(x2 + z2) * il2 - rb;
    if (sign(y) * a2 * y2 < k) return sqrt(x2 + y2) * il2 - ra;
    return (sqrt(max(x2 * a2 * il2, 0.0)) + y * rr) * il2 - ra;
}

fragment float4 stroke_frag(Stroke_Out in [[stage_in]]) {
    float d = round_cone(in.position.xy, in.seg.xy, in.seg.zw, in.radii.x, in.radii.y);
    float cov = clamp(0.5 - d, 0.0, 1.0); // soft over one texel, as a hard dab's edge is
    return float4(cov);
}

// ------------------------------------------------- the fill and the copy
//
// Two passes Vulkan gets from its API and Metal does not.
//
// **Fill.** vkCmdClearAttachments clears a rectangle of an attachment;
// Metal's loadAction clears the whole of one. So a fill is a full-screen
// draw of a constant, confined by the scissor — which is what the viewport
// and scissor already are for every other canvas pass.
//
// **Copy.** vkCmdCopyImage moves texels between canvases of one format and
// vkCmdBlitImage converts between two. Metal's blit encoder does the first
// but refuses the second, so a copy between formats is a draw as well: one
// texel read, one written, no filtering, the values converted by the
// formats as they are read and written (an 8-bit 255 becomes a 16-bit
// 65535). A single-channel canvas reads as (r, 0, 0, 1), which is the texel
// rule api_canvas.odin states.

struct Fill_Push {
    float4 value;
    int2   off;    // copy: source texel = destination pixel + off
    uint   pad0, pad1;
};

fragment float4 fill_main(FS_Out in [[stage_in]], constant Fill_Push& pc [[buffer(0)]]) {
    return pc.value;
}

fragment float4 copy_main(FS_Out in [[stage_in]],
                          constant Fill_Push& pc [[buffer(0)]],
                          texture2d<float> src_tex [[texture(0)]]) {
    return src_tex.read(uint2(int2(in.position.xy) + pc.off), 0);
}
