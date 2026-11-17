#version 450
// Baldr canvas blend: a source canvas composited onto
// a destination canvas with one of Photoshop's 27 blend modes, an opacity
// and a mask, drawn into the destination over a copy of what was there (the
// backdrop). Every formula here has its twin in baldr/canvas_blend.odin, the
// CPU reference the tests check; change one, change both.
//
// Compositing is W3C Compositing and Blending Level 1's source-over with
// blending: the blended colour B(cb, cs) replaces the source where the
// backdrop is opaque, and the result is laid over the backdrop by the
// source's alpha (× opacity × mask). Values are straight alpha. In linear
// maths both are decoded from their space's curve first and the result
// encoded again; otherwise the stored values are blended, as Photoshop
// does.

layout(set = 0, binding = 0) uniform sampler2D src_tex;
layout(set = 1, binding = 0) uniform sampler2D back_tex;
layout(set = 2, binding = 0) uniform sampler2D mask_tex;

layout(push_constant) uniform Push {
    ivec2 src_off;  // source texel = destination pixel + src_off
    ivec2 back_off; // backdrop texel = destination pixel + back_off
    ivec2 mask_off; // mask texel = destination pixel + mask_off
    uint  mode;
    uint  flags;    // bit 0 linear maths, bit 1 a mask, bits 2-3 the destination's curve, bits 4-5 the source's,
                    // bit 6 a solid colour for the source (`color`), bit 7 erase (the source's alpha takes away)
    float opacity;
    uint  seed;     // Dissolve's pattern
    uint  pad0, pad1;
    vec4  color;    // the solid source (canvas_paint)
} pc;

layout(location = 0) out vec4 out_color;

#include "blend_common.glsl"

void main() {
    ivec2 p   = ivec2(gl_FragCoord.xy);
    vec4  src = (pc.flags & 64u) != 0u ? pc.color : texelFetch(src_tex, p + pc.src_off, 0);
    vec4  dst = texelFetch(back_tex, p + pc.back_off, 0);
    float m   = (pc.flags & 2u) != 0u ? texelFetch(mask_tex, p + pc.mask_off, 0).r : 1.0;
    float as  = clamp(src.a * pc.opacity * m, 0.0, 1.0);
    float ab  = clamp(dst.a, 0.0, 1.0);
    if (pc.mode == 1u) { // dissolve: the source's alpha becomes the chance of a whole pixel
        float r = float(hash(uint(p.x) * 1973u + uint(p.y) * 9277u + pc.seed) >> 8u) / 16777216.0;
        as = r < as ? 1.0 : 0.0;
    }
    if ((pc.flags & 128u) != 0u) { // erase: the backdrop's alpha taken away by the source's
        out_color = vec4(dst.rgb, ab * (1.0 - as));
        return;
    }
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
