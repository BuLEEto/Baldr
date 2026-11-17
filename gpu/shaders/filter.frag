#version 450
// Baldr canvas filters and adjustments: a colour
// matrix, per-channel curves, conversion between colour spaces, an app's 3D
// LUT, and a Gaussian blur (two passes) with an unsharp mask on its second.
// The input is always a copy of the source's rectangle (with a margin for
// the blur), so a filter may write back onto its own canvas. Every formula
// has its twin in baldr/canvas_filter.odin, the CPU reference.

layout(set = 0, binding = 0) uniform sampler2D in_tex;  // the input copy, or the blur's first pass
layout(set = 1, binding = 0) uniform sampler2D aux_tex; // a curve, a LUT, or the unblurred input

layout(push_constant) uniform Push {
    ivec2 in_off;   // input texel = pixel + in_off
    ivec2 in_max;   // the input's last texel: taps past it are clamped (the canvas's edge)
    ivec2 aux_off;  // aux texel = pixel + aux_off
    uint  kind;     // 0 matrix, 1 curves, 2 convert, 3 LUT, 4 blur across, 5 blur down, 6 blur down and sharpen
    uint  flags;    // bit 0 linear, bits 2-3 the input's curve, bits 4-5 the output's
    float a;        // blur: sigma
    float b;        // sharpen: amount
    float c;        // sharpen: threshold
    uint  pad;
    vec4  m0, m1, m2, m3; // matrix rows (convert: the first three, 3 × 3)
    vec4  moff;           // matrix offsets
} pc;

layout(location = 0) out vec4 out_color;

float decode1(float c, uint curve) {
    if (curve == 2u) return c;
    if (curve == 1u) return pow(max(c, 0.0), 2.19921875);
    return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4);
}
float encode1(float c, uint curve) {
    if (curve == 2u) return c;
    if (curve == 1u) return pow(max(c, 0.0), 1.0 / 2.19921875);
    return c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1.0 / 2.4) - 0.055;
}
vec3 decode(vec3 c, uint curve) { return vec3(decode1(c.r, curve), decode1(c.g, curve), decode1(c.b, curve)); }
vec3 encode(vec3 c, uint curve) { return vec3(encode1(c.r, curve), encode1(c.g, curve), encode1(c.b, curve)); }

vec4 fetch_in(ivec2 t) { return texelFetch(in_tex, clamp(t, ivec2(0), pc.in_max), 0); }

float curve1(float v, int ch) {
    int   n = textureSize(aux_tex, 0).x;
    float x = clamp(v, 0.0, 1.0) * float(n - 1);
    int   i = min(int(floor(x)), n - 2);
    float t = x - float(i);
    return mix(texelFetch(aux_tex, ivec2(i, 0), 0)[ch], texelFetch(aux_tex, ivec2(i + 1, 0), 0)[ch], t);
}

vec3 lut3(vec3 v) { // size n: n × n slices side by side, red across a slice, green down, blue by slice
    int  n = textureSize(aux_tex, 0).y;
    vec3 x = clamp(v, 0.0, 1.0) * float(n - 1);
    ivec3 i = min(ivec3(floor(x)), ivec3(n - 2));
    vec3 t = x - vec3(i);
    vec3 r = vec3(0.0);
    for (int k = 0; k < 8; k++) {
        ivec3 o = ivec3(k & 1, (k >> 1) & 1, (k >> 2) & 1);
        float w = (o.x == 1 ? t.x : 1.0 - t.x) * (o.y == 1 ? t.y : 1.0 - t.y) * (o.z == 1 ? t.z : 1.0 - t.z);
        ivec3 p = i + o;
        r += w * texelFetch(aux_tex, ivec2(p.x + p.z * n, p.y), 0).rgb;
    }
    return r;
}

// blur taps: sigma's Gaussian out to three sigmas, weights normalised
vec4 blur(ivec2 p, ivec2 step, bool first, uint curve, bool linear) {
    float s = max(pc.a, 0.01);
    int   r = int(ceil(3.0 * s));
    vec4  sum = vec4(0.0);
    float wsum = 0.0;
    for (int d = -r; d <= r; d++) {
        float w = exp(-float(d * d) / (2.0 * s * s));
        vec4  v = fetch_in(p + pc.in_off + step * d);
        if (first) { // straight → premultiplied (and to light, in linear maths)
            if (linear) v.rgb = decode(v.rgb, curve);
            v.rgb *= v.a;
        }
        sum += w * v;
        wsum += w;
    }
    return sum / wsum;
}

void main() {
    ivec2 p = ivec2(gl_FragCoord.xy);
    bool  linear = (pc.flags & 1u) != 0u;
    uint  icurve = (pc.flags >> 2u) & 3u;
    uint  ocurve = (pc.flags >> 4u) & 3u;
    if (pc.kind == 4u) { // across: premultiplied, into the float intermediate
        out_color = blur(p, ivec2(1, 0), true, icurve, linear);
        return;
    }
    if (pc.kind == 5u || pc.kind == 6u) { // down, then straight again
        vec4 v = blur(p, ivec2(0, 1), false, icurve, linear);
        vec3 c = v.a > 0.0 ? v.rgb / v.a : vec3(0.0);
        if (pc.kind == 6u) { // unsharp: the original pushed away from its blur where they differ enough
            vec4 o = texelFetch(aux_tex, p + pc.aux_off, 0);
            vec3 oc = linear ? decode(o.rgb, icurve) : o.rgb;
            vec3 d = oc - c;
            vec3 sharp = oc + pc.b * d;
            c = vec3(abs(d.r) >= pc.c ? sharp.r : oc.r, abs(d.g) >= pc.c ? sharp.g : oc.g, abs(d.b) >= pc.c ? sharp.b : oc.b);
            v.a = o.a;
        }
        if (linear) c = encode(c, ocurve);
        out_color = vec4(c, v.a);
        return;
    }
    vec4 v = fetch_in(p + pc.in_off);
    if (pc.kind == 2u) { // convert: the input's space to the output's
        vec3 l = decode(v.rgb, icurve);
        l = vec3(dot(pc.m0.rgb, l), dot(pc.m1.rgb, l), dot(pc.m2.rgb, l));
        out_color = vec4(encode(l, ocurve), v.a);
        return;
    }
    if (linear) v.rgb = decode(v.rgb, icurve);
    if (pc.kind == 0u) {
        v = vec4(dot(pc.m0, v), dot(pc.m1, v), dot(pc.m2, v), dot(pc.m3, v)) + pc.moff;
    } else if (pc.kind == 1u) {
        v = vec4(curve1(v.r, 0), curve1(v.g, 1), curve1(v.b, 2), curve1(v.a, 3));
    } else if (pc.kind == 3u) {
        v.rgb = lut3(v.rgb);
    }
    if (linear) v.rgb = encode(v.rgb, ocurve);
    out_color = v;
}
