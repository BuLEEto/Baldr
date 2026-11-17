#version 450
// Baldr canvas transform: a source canvas drawn into another
// through a 3×3 matrix — moved, scaled, rotated, skewed — resampled, then
// laid on the destination exactly as blend.frag lays a source on it.
//
// Each destination texel maps back through the inverse, and the source is
// gathered around that point with a kernel whose width follows the scale:
// shrinking widens it, so every source texel inside the destination texel is
// counted and a photo scaled down does not sparkle. Texels outside the
// source rectangle count as nothing, and what the kernel loses to them fades
// the alpha — which is the clean edge on a rotated layer. The gather is
// premultiplied, so a texel beside a clear one keeps its own colour at a
// lower alpha instead of darkening towards black.
//
// Its twin is baldr/canvas_transform.odin, the CPU reference the tests
// check. Change one, change both.

layout(set = 0, binding = 0) uniform sampler2D src_tex;
layout(set = 1, binding = 0) uniform sampler2D back_tex;
layout(set = 2, binding = 0) uniform sampler2D mask_tex;

layout(push_constant) uniform Push {
    mat3  inv;        // destination texel → source texel
    ivec2 back_off;   // backdrop texel = destination pixel + back_off
    ivec2 mask_off;   // mask texel = destination pixel + mask_off
    ivec4 src_rect;   // x, y, w, h: outside it the source is transparent
    uint  mode;
    uint  flags;      // bit 0 linear maths, bit 1 a mask, bits 2-3 the destination's curve, bits 4-5 the source's
    uint  kernel;     // 0 nearest, 1 bilinear, 2 bicubic (Catmull-Rom), 3 Lanczos3
    float opacity;
} pc;

layout(location = 0) out vec4 out_color;

#include "blend_common.glsl"

// TRANSFORM_MAX_TAPS bounds the gather in each direction, as the reference
// does: past this the kernel keeps its width but steps through it.
const int TRANSFORM_MAX_TAPS = 16;

float kernel_weight(uint f, float t) {
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

float kernel_radius(uint f) {
    if (f == 0u) return 0.5;
    if (f == 1u) return 1.0;
    if (f == 2u) return 2.0;
    return 3.0;
}

vec2 map_point(mat3 m, vec2 p) {
    vec3 v = m * vec3(p, 1.0);
    return abs(v.z) > 1e-9 ? v.xy / v.z : v.xy;
}

void main() {
    ivec2 p = ivec2(gl_FragCoord.xy);
    vec2  c = map_point(pc.inv, gl_FragCoord.xy);

    // how much source one destination texel covers, per axis: the lengths of
    // the inverse's columns, never less than one texel
    // …except for nearest, which is chosen because it takes one texel whole
    vec2 scale = pc.kernel == 0u ? vec2(1.0)
               : vec2(max(length(vec2(pc.inv[0][0], pc.inv[0][1])), 1.0),
                      max(length(vec2(pc.inv[1][0], pc.inv[1][1])), 1.0));
    float reach = kernel_radius(pc.kernel);
    vec2  r     = reach * scale;
    vec2  step  = max(2.0 * r / float(TRANSFORM_MAX_TAPS), vec2(1.0));

    vec4  sum    = vec4(0.0);
    float weight = 0.0;
    float full   = 0.0;
    if (pc.kernel == 0u) { // one texel, whole: no kernel to run
        ivec2 s = ivec2(floor(c));
        if (s.x >= pc.src_rect.x && s.y >= pc.src_rect.y &&
            s.x < pc.src_rect.x + pc.src_rect.z && s.y < pc.src_rect.y + pc.src_rect.w) {
            vec4 t = texelFetch(src_tex, s, 0);
            sum = vec4(t.rgb * t.a, t.a); // premultiplied, as the gather is
            weight = 1.0;
        }
        full = 1.0;
    } else {
    // Counted, not accumulated: a loop whose end is a float comparison can
    // run away on a GPU (one NaN in the matrix and the device is lost), and
    // the count is what the reference walks too.
    ivec2 taps = ivec2(clamp(ceil(2.0 * r / step), vec2(1.0), vec2(float(TRANSFORM_MAX_TAPS))));
    vec2  u0   = floor((c - r) / step) * step + step * 0.5;
    for (int i = 0; i < taps.x; i++) {
        float u = u0.x + float(i) * step.x;
        float wx = kernel_weight(pc.kernel, (u - c.x) / scale.x);
        if (wx == 0.0) continue;
        for (int j = 0; j < taps.y; j++) {
            float v = u0.y + float(j) * step.y;
            float k = wx * kernel_weight(pc.kernel, (v - c.y) / scale.y);
            if (k == 0.0) continue;
            full += k;
            ivec2 s = ivec2(floor(u), floor(v));
            if (s.x < pc.src_rect.x || s.y < pc.src_rect.y ||
                s.x >= pc.src_rect.x + pc.src_rect.z || s.y >= pc.src_rect.y + pc.src_rect.w) continue;
            // Premultiplied, always: averaging straight colours lets a clear
            // neighbour — black with zero alpha — pull the colour towards
            // black, and a transparent layer grows a dark fringe when it is
            // scaled or rotated.
            vec4 t = texelFetch(src_tex, s, 0);
            sum += vec4(t.rgb * t.a, t.a) * k;
            weight += k;
        }
    }
    }
    vec4 dst = texelFetch(back_tex, p + pc.back_off, 0);
    if (weight <= 0.0) { // nothing of the source reaches here: the backdrop stands
        out_color = dst;
        return;
    }
    // The colour comes back out of the premultiplied sum; partial coverage
    // of the source rectangle fades the edge.
    vec4 src = vec4(sum.a > 1e-6 ? sum.rgb / sum.a : vec3(0.0),
                    max(sum.a / weight, 0.0) * clamp(weight / max(full, 1e-6), 0.0, 1.0));

    float m  = (pc.flags & 2u) != 0u ? texelFetch(mask_tex, p + pc.mask_off, 0).r : 1.0;
    float as = clamp(src.a * pc.opacity * m, 0.0, 1.0);
    float ab = clamp(dst.a, 0.0, 1.0);
    bool linear = (pc.flags & 1u) != 0u;
    uint dcurve = (pc.flags >> 2u) & 3u;
    uint scurve = (pc.flags >> 4u) & 3u;
    vec3 cb = linear ? decode(dst.rgb, dcurve) : dst.rgb;
    vec3 cs = linear ? decode(src.rgb, scurve) : src.rgb;
    vec3 mixed = (1.0 - ab) * cs + ab * blend(pc.mode, cb, cs);
    float ao = as + ab * (1.0 - as);
    vec3 co = ao > 0.0 ? (as * mixed + ab * (1.0 - as) * cb) / ao : vec3(0.0);
    if (linear) co = encode(co, dcurve);
    out_color = vec4(co, ao);
}
