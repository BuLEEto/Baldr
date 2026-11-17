// ui.metal — the Metal port of ui.vert and ui.frag.
//
// Ported character for character from the GLSL beside it, not paraphrased
// from its comments, which leave out detail the maths depends on. Where the
// two must differ, the comment says why.
//
// Two differences that are structural rather than stylistic:
//   - Metal's NDC has y up where Vulkan's has y down, so the vertex shader
//     flips. ui.vert says "no flip is needed", which is true only for Vulkan.
//   - MSL aligns float4 to 16 bytes, so the vertex struct must use packed_
//     types or it becomes 96 bytes against Odin's 80, every vertex after the
//     first is read from the wrong offset, and nothing draws.

#include <metal_stdlib>
using namespace metal;

struct Vertex {                 // gpu.Vertex, 80 bytes, field for field
    packed_float2 pos;
    packed_float2 uv;
    packed_float4 color;
    packed_float4 rect;
    float         radius;
    float         border_w;
    packed_float4 border;
    uint          kind;
    uint          pad;
};

struct V_Out {
    float4 position [[position]];
    float2 v_pos;
    float2 v_uv;
    float4 v_color;
    float4 v_rect;
    float2 v_params;
    float4 v_border;
    uint   v_kind [[flat]];
};

vertex V_Out v_main(uint vid [[vertex_id]],
                    const device Vertex *verts [[buffer(0)]],
                    constant float2 &viewport [[buffer(1)]]) {
    const device Vertex &v = verts[vid];
    float2 ndc = v.pos / viewport * 2.0 - 1.0;
    ndc.y = -ndc.y;
    V_Out o;
    o.position = float4(ndc, 0.0, 1.0);
    o.v_pos    = v.pos;
    o.v_uv     = v.uv;
    o.v_color  = v.color;
    o.v_rect   = v.rect;
    o.v_params = float2(v.radius, v.border_w);
    o.v_border = v.border;
    o.v_kind   = v.kind;
    return o;
}

static float sd_round_rect(float2 p, float2 half_size, float r) {
    float2 q = abs(p) - half_size + r;
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
}

static float sd_round_rect_c(float2 p, float2 half_size, float r, uint square) {
    uint corner = p.x < 0.0 ? (p.y < 0.0 ? 0u : 3u) : (p.y < 0.0 ? 1u : 2u);
    return sd_round_rect(p, half_size, ((square >> corner) & 1u) != 0u ? 0.0 : r);
}

static float coverage(float d) { return clamp(0.5 - d, 0.0, 1.0); }

static float2 erf2(float2 x) {
    float2 s = sign(x), a = abs(x);
    x = 1.0 + (0.278393 + (0.230389 + 0.078108 * (a * a)) * a) * a;
    x *= x;
    return s - s / (x * x);
}

static float gaussian(float x, float sigma) {
    return exp(-(x * x) / (2.0 * sigma * sigma)) / (2.5066282746 * sigma);
}

static float shadow_x(float x, float y, float sigma, float r, float2 half_size) {
    float  delta  = min(half_size.y - r - abs(y), 0.0);
    float  curved = half_size.x - r + sqrt(max(0.0, r * r - delta * delta));
    float2 edge   = 0.5 + 0.5 * erf2((x + float2(-curved, curved)) * (0.70710678 / sigma));
    return edge.y - edge.x;
}

static float shadow_rounded_rect(float2 p, float2 half_size, float r, float sigma) {
    float low   = p.y - half_size.y;
    float high  = p.y + half_size.y;
    float start = clamp(-3.0 * sigma, low, high);
    float end   = clamp(3.0 * sigma, low, high);
    float step  = (end - start) / 4.0;
    float y     = start + step * 0.5;
    float a     = 0.0;
    for (int i = 0; i < 4; i++) {
        a += shadow_x(p.x, p.y - y, sigma, r, half_size) * gaussian(y, sigma) * step;
        y += step;
    }
    return a;
}

fragment float4 f_main(V_Out in [[stage_in]],
                       texture2d<float> tex [[texture(0)]],
                       sampler samp [[sampler(0)]]) {
    uint kind   = in.v_kind & 0xFFu;
    uint square = (in.v_kind >> 8u) & 0xFu;

    if (kind == 0u) {                           // KIND_QUAD
        float2 half_size = in.v_rect.zw * 0.5;
        float2 centre    = in.v_rect.xy + half_size;
        float  r         = clamp(in.v_params.x, 0.0, min(half_size.x, half_size.y));
        float  d         = sd_round_rect_c(in.v_pos - centre, half_size, r, square);
        float  outer     = coverage(d);
        float4 col       = in.v_color;
        float  bw        = in.v_params.y;
        if (bw > 0.0) {
            // Inner shape = outer shrunk by bw. Mixed premultiplied so a
            // transparent fill with an opaque border composites correctly,
            // then back to straight alpha for the blend state.
            float  inner   = coverage(d + bw);
            float3 fill_pm = in.v_color.rgb * in.v_color.a;
            float3 ring_pm = in.v_border.rgb * in.v_border.a;
            float3 rgb_pm  = mix(ring_pm, fill_pm, inner);
            float  a       = mix(in.v_border.a, in.v_color.a, inner);
            col = float4(rgb_pm / max(a, 1e-6), a);
        }
        return float4(col.rgb, col.a * outer);
    }

    if (kind == 1u) {                           // KIND_ALPHA_GLYPH
        // Coverage blended in linear light reads too thin for dark text on a
        // light ground (the swapchain is sRGB, so the blend is linear). Lift
        // dark text toward what a perceptual blend gives; light text already
        // looks right and is left alone.
        float a   = tex.sample(samp, in.v_uv).r;
        float lum = dot(in.v_color.rgb, float3(0.2126, 0.7152, 0.0722));
        float g   = mix(0.62, 1.0, smoothstep(0.0, 0.35, lum));
        a = pow(a, g);
        return float4(in.v_color.rgb, in.v_color.a * a);
    }

    if (kind == 2u) {                           // KIND_RGBA_GLYPH
        float4 t = tex.sample(samp, in.v_uv);
        return float4(t.rgb, t.a * in.v_color.a);
    }

    if (kind == 3u) {                           // KIND_SHADOW
        float2 half_size = in.v_rect.zw * 0.5;
        float2 centre    = in.v_rect.xy + half_size;
        float2 p         = in.v_pos - centre;
        uint   corner    = p.x < 0.0 ? (p.y < 0.0 ? 0u : 3u) : (p.y < 0.0 ? 1u : 2u);
        float  r         = ((square >> corner) & 1u) != 0u ? 0.0 : clamp(in.v_params.x, 0.0, min(half_size.x, half_size.y));
        float  a         = shadow_rounded_rect(p, half_size, r, max(in.v_params.y * 0.5, 0.25));
        if (in.v_border.z > 0.0) {              // the hole a see-through card leaves
            float2 hh = in.v_border.zw * 0.5;
            float  hr = clamp(in.v_params.x, 0.0, min(hh.x, hh.y));
            a *= 1.0 - coverage(sd_round_rect_c(in.v_pos - (in.v_border.xy + hh), hh, hr, square));
        }
        return float4(in.v_color.rgb, in.v_color.a * a);
    }

    if (kind == 5u) {                           // KIND_IMAGE, rounded and clipped
        float2 half_size = in.v_rect.zw * 0.5;
        float2 centre    = in.v_rect.xy + half_size;
        float  r         = clamp(in.v_params.x, 0.0, min(half_size.x, half_size.y));
        float  cov       = coverage(sd_round_rect_c(in.v_pos - centre, half_size, r, square));
        float4 t         = tex.sample(samp, in.v_uv);
        return float4(t.rgb * in.v_color.rgb, t.a * in.v_color.a * cov);
    }

    if (kind == 6u) {                           // KIND_GLOW
        // A glyph's coverage under a Gaussian of sigma = radius / 2 (as CSS
        // drop-shadow blurs): taps spread evenly over three sigmas on a
        // golden-angle spiral, weighted, and turned per pixel so the few taps
        // read as fine grain rather than rings.
        float sigma = max(in.v_border.z * 0.5, 0.25);
        float reach = 3.0 * sigma;
        float spin  = 6.2831853 * fract(52.9829189 * fract(dot(in.v_pos, float2(0.06711056, 0.00583715))));
        float sum   = 0.0;
        float wsum  = 0.0;
        const int TAPS = 48;                    // 24 leaves a faint speckle at the letters' edges
        for (int i = 0; i < TAPS; i++) {
            float  d   = reach * sqrt((float(i) + 0.5) / float(TAPS));
            float  ang = float(i) * 2.3999632 + spin;
            float2 uv  = in.v_uv + float2(cos(ang), sin(ang)) * d * in.v_border.xy;
            float4 t   = tex.sample(samp, uv);
            float  in_box = step(in.v_rect.x, uv.x) * step(uv.x, in.v_rect.z)
                          * step(in.v_rect.y, uv.y) * step(uv.y, in.v_rect.w);
            float  w   = exp(-(d * d) / (2.0 * sigma * sigma));
            sum  += (in.v_border.w > 0.5 ? t.a : t.r) * in_box * w;
            wsum += w;
        }
        return float4(in.v_color.rgb, in.v_color.a * sum / max(wsum, 1e-6));
    }

    if (kind == 7u) {                           // KIND_HIGHLIGHT
        // the rounded rect less itself moved down by the line's width
        float2 half_size = in.v_rect.zw * 0.5;
        float2 centre    = in.v_rect.xy + half_size;
        float  r         = clamp(in.v_params.x, 0.0, min(half_size.x, half_size.y));
        float  outer     = coverage(sd_round_rect_c(in.v_pos - centre, half_size, r, square));
        float  lower     = coverage(sd_round_rect_c(in.v_pos - centre - float2(0.0, in.v_params.y), half_size, r, square));
        return float4(in.v_color.rgb, in.v_color.a * outer * (1.0 - lower));
    }

    if (kind == 8u) {                           // KIND_LINE
        // Distance to the segment, then the same 1 px fringe a quad uses: a
        // polyline is drawn as capsules, so joins and ends are round without
        // any geometry for them.
        float2 a    = in.v_rect.xy;
        float2 b    = in.v_rect.zw;
        float2 pa   = in.v_pos - a;
        float2 ba   = b - a;
        float  len2 = max(dot(ba, ba), 1e-6);
        float  h    = clamp(dot(pa, ba) / len2, 0.0, 1.0);
        float  d    = length(pa - ba * h) - in.v_params.x;
        if (in.v_border.x > 0.5) {              // flat cap: cut the capsule back to the ends
            float along = dot(pa, ba) / sqrt(len2);
            float run   = sqrt(len2);
            d = max(d, max(-along, along - run));
        }
        return float4(in.v_color.rgb, in.v_color.a * clamp(0.5 - d, 0.0, 1.0));
    }

    if (kind == 4u) {                           // KIND_BACKDROP
        float2 half_size = in.v_rect.zw * 0.5;
        float2 centre    = in.v_rect.xy + half_size;
        float  r         = clamp(in.v_params.x, 0.0, min(half_size.x, half_size.y));
        float  cov       = coverage(sd_round_rect_c(in.v_pos - centre, half_size, r, square));
        // The blurred scene is premultiplied. On an opaque target it is all
        // opaque; on a transparent one (a popup, a glass bar) little or none
        // of it is, and the tint then lets the compositor's blur show through.
        float4 s = tex.sample(samp, in.v_uv);
        float3 b = s.a > 0.0 ? s.rgb / s.a : float3(0.0);
        float  lum = dot(b, float3(0.2126, 0.7152, 0.0722));
        b = mix(float3(lum), b, in.v_border.x);          // saturation (1 = unchanged)
        float a = in.v_color.a + s.a * (1.0 - in.v_color.a); // tint over it
        b = (in.v_color.rgb * in.v_color.a + b * s.a * (1.0 - in.v_color.a)) / max(a, 1e-6);
        // Grain hides banding. Scaled by sqrt(luminance) so it is about the
        // same fraction of an sRGB step everywhere: a flat amount reads as
        // static on dark surfaces (linear space is very compressed there).
        float n = fract(sin(dot(floor(in.v_pos), float2(12.9898, 78.233))) * 43758.5453) - 0.5;
        b += n * in.v_border.y * sqrt(max(b, float3(0.0)));
        return float4(b, a * cov * (1.0 - in.v_border.z));
    }

    // Every kind is handled above, so one arriving here is a batcher bug;
    // magenta makes it visible.
    return float4(1.0, 0.0, 1.0, 0.5);
}
