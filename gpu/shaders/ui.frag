#version 450
// Baldr UI fragment shader.
//   kind 0: rounded-rect signed distance; fill + border ring (border grows
//           inward from the rect edge), 1 px anti-aliasing fringe.
//   kind 1: alpha glyph  -> color tinted by texture.r
//   kind 2: RGBA glyph   -> texture.rgb, texture.a * color.a
//   kind 3: soft shadow  -> color, the rounded rect blurred as CSS box-shadow
//           blurs it: a Gaussian of sigma params.y / 2 (half strength at the
//           edge, gone 1.5 x blur out).
//           border (x, y, w, h), when w > 0, is a rect it leaves clear: the
//           see-through card it sits under.
//   kind 4: backdrop     -> frosted glass: the blurred scene (tex, uv = screen
//           position) desaturated/saturated by border.x, tinted by color
//           (color.a = tint strength), grain by border.y, rounded by params.x,
//           faded out by border.z (its node's transition).
//           Keeps the scene's alpha: over a transparent target the tint alone.
//   kind 5: image        -> texture × color, corners cut like a quad; a
//           picture's own texture drawn smaller averages its footprint
//           across its mip levels (picture())
//   kind 6: glow         -> a glyph's coverage (rect = its uv box, border.xy =
//           uv per px, border.z = radius, border.w = 1 for RGBA) blurred
//   kind 7: highlight    -> a params.y px line along the rounded rect's top
//   kind 8: line segment -> a capsule: rect = (x0, y0, x1, y1) in px,
//           params.x = half width, border.x = 1 for a flat cap (a bar's edge)
//           instead of a round one (a polyline's joins). One AA fringe, as
//           the rounded rect has.
// Bits 8-11 of the kind are the corners a rounded shape keeps square (top-left,
// top-right, bottom-right, bottom-left): radius 0 there. Bit 12 on a picture
// asks for hard pixels when it is magnified. Bit 13 marks a canvas, whose
// texels are its colour space's values (bits 14-15: sRGB, Display P3, Adobe
// RGB, linear), decoded here to the linear sRGB the pipeline blends in.
// Output is straight alpha; the pipeline blends SRC_ALPHA / ONE_MINUS_SRC_ALPHA.

layout(location = 0)      in vec2  v_pos;
layout(location = 1)      in vec2  v_uv;
layout(location = 2)      in vec4  v_color;
layout(location = 3)      in vec4  v_rect;
layout(location = 4)      in vec2  v_params;
layout(location = 5)      in vec4  v_border;
layout(location = 6) flat in uint  v_kind;

layout(set = 0, binding = 0) uniform sampler2D tex;

layout(location = 0) out vec4 out_color;

// Signed distance from p (relative to the rect centre) to a rounded rect with
// half extents `half_size` and corner radius r. Negative inside.
float sd_round_rect(vec2 p, vec2 half_size, float r) {
    vec2 q = abs(p) - half_size + r;
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
}

// The same with the corners in `square` (bit 0 top-left, 1 top-right,
// 2 bottom-right, 3 bottom-left; y down) left square: the radius of the
// corner p lies toward.
float sd_round_rect_c(vec2 p, vec2 half_size, float r, uint square) {
    uint corner = p.x < 0.0 ? (p.y < 0.0 ? 0u : 3u) : (p.y < 0.0 ? 1u : 2u);
    return sd_round_rect(p, half_size, ((square >> corner) & 1u) != 0u ? 0.0 : r);
}

// Pixel coverage for a signed distance: 1 px linear fringe centred on the edge.
float coverage(float d) {
    return clamp(0.5 - d, 0.0, 1.0);
}

// erf, to within 5e-4 (Abramowitz and Stegun 7.1.27).
vec2 erf2(vec2 x) {
    vec2 s = sign(x), a = abs(x);
    x = 1.0 + (0.278393 + (0.230389 + 0.078108 * (a * a)) * a) * a;
    x *= x;
    return s - s / (x * x);
}

float gaussian(float x, float sigma) {
    return exp(-(x * x) / (2.0 * sigma * sigma)) / (2.5066282746 * sigma);
}

// A rounded rect's shadow: the row of it at height y blurred across x in closed
// form, integrated along y over four Gaussian-weighted steps (Evan Wallace's
// approximation of the convolution, exact for straight edges).
float shadow_x(float x, float y, float sigma, float r, vec2 half_size) {
    float delta  = min(half_size.y - r - abs(y), 0.0);
    float curved = half_size.x - r + sqrt(max(0.0, r * r - delta * delta));
    vec2  edge   = 0.5 + 0.5 * erf2((x + vec2(-curved, curved)) * (0.70710678 / sigma));
    return edge.y - edge.x;
}

float shadow_rounded_rect(vec2 p, vec2 half_size, float r, float sigma) {
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

// A canvas's values to linear sRGB: the space's curve undone,
// then its primaries mapped to sRGB's (D65 throughout; matrices from the
// primaries). Colours outside sRGB are clipped by the target for now.
float srgb_decode(float c) {
    return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4);
}
vec3 canvas_decode(vec3 c, uint space) {
    if (space == 3u) return c;                                   // linear
    if (space == 2u) {                                           // Adobe RGB (1998): gamma 563/256
        vec3 l = pow(max(c, vec3(0.0)), vec3(2.19921875));
        return vec3(1.3983557 * l.r - 0.3983557 * l.g,
                    l.g,
                    -0.0429290 * l.g + 1.0429290 * l.b);
    }
    vec3 l = vec3(srgb_decode(c.r), srgb_decode(c.g), srgb_decode(c.b));
    if (space == 1u) {                                           // Display P3: sRGB's curve, wider primaries
        return vec3( 1.2249402 * l.r - 0.2249402 * l.g,
                    -0.0420570 * l.r + 1.0420570 * l.g,
                    -0.0196376 * l.r - 0.0786360 * l.g + 1.0982736 * l.b);
    }
    return l;                                                    // sRGB
}

// A picture's texel for this pixel. A picture with mip levels (its own
// texture) drawn smaller than it is averages its pixel's footprint: 4 x 4
// bilinear taps across it on the level one finer than the footprint (2-4
// texels to a pixel), which keeps nearly the detail of an area average with
// less aliasing than one, where trilinear sampling alone blurs to half the
// contrast near the screen's limit. At its size or larger, and from the
// atlas (one level, nothing reduced past two), one bilinear tap: 100 % stays
// pixel-exact.
//
// `mode` is how it is sampled where it is *magnified* (Pixels in gpu/api.odin):
// 0 auto, 1 smooth, 2 hard. Auto crossfades a bilinear tap into a nearest one
// between 2 and 4 device pixels a texel, so a viewer goes crisp as it is
// zoomed in without popping at a threshold.
vec4 picture(vec2 uv, uint mode) {
    int   levels = textureQueryLevels(tex);
    vec2  dx     = dFdx(uv);
    vec2  dy     = dFdy(uv);
    vec2  size   = vec2(textureSize(tex, 0));
    float rho    = max(length(dx * size), length(dy * size)); // texels to a pixel at level 0
    if (rho < 1.0 && mode != 1u) {
        // magnified: `mag` device pixels to a texel. Hard pixels are what an
        // editor at 800 % wants and what auto arrives at by 4.
        float mag  = 1.0 / max(rho, 1e-6);
        float hard = mode == 2u ? 1.0 : clamp((mag - 2.0) / 2.0, 0.0, 1.0);
        if (hard > 0.0) {
            // the centre of the texel the pixel falls in, which a linear
            // filter returns as that texel alone
            vec4 near = textureLod(tex, (floor(uv * size) + 0.5) / size, 0.0);
            return hard >= 1.0 ? near : mix(texture(tex, uv), near, hard);
        }
    }
    if (levels <= 1 || rho < 1.03) {
        return texture(tex, uv);
    }
    float level = clamp(floor(log2(rho)) - 1.0, 0.0, float(levels - 1));
    vec4  sum   = vec4(0.0);
    for (int j = 0; j < 4; j++) {
        for (int i = 0; i < 4; i++) {
            vec2 o = (vec2(float(i), float(j)) + 0.5) * 0.25 - 0.5;
            sum += textureLod(tex, uv + dx * o.x + dy * o.y, level);
        }
    }
    return sum * (1.0 / 16.0);
}

// A line between a magnified picture's texels: 1 device pixel wide, fading
// in from 8 device pixels a texel and fully there from 24. Below 8 a 1-pixel
// line between 8-pixel texels is a grey wash over the picture rather than a
// grid, so there is none.
//
// Its ink is black over a light texel and white over a dark one, so it shows
// on any picture without a colour to pass in, and a mid grey where the picture
// is transparent, which shows over either a light or a dark backdrop. It is
// composited *over* the texel rather than mixed into it, so the grid is there
// across a transparent part of a picture too.
vec4 pixel_grid(vec4 col, vec2 uv) {
    vec2  size = vec2(textureSize(tex, 0));
    vec2  tc   = uv * size;
    vec2  w    = max(fwidth(tc), vec2(1e-6));    // texels to a pixel, per axis
    float mag  = 1.0 / max(w.x, w.y);            // device pixels to a texel
    float fade = clamp((mag - 8.0) / 16.0, 0.0, 1.0);
    if (fade <= 0.0) return col;
    vec2  d    = abs(fract(tc + 0.5) - 0.5) / w; // pixels to the nearest texel edge
    // how much of this pixel a 1-pixel line on that edge covers. Not a ramp
    // over half a pixel: no fragment centre lands nearer an edge than 0.5 px,
    // so that ramp would draw nothing; the two fragments straddling an edge
    // take half the ink each.
    float line = clamp(1.0 - min(d.x, d.y), 0.0, 1.0);
    if (line <= 0.0) return col;
    float lum  = dot(col.rgb, vec3(0.2126, 0.7152, 0.0722));
    vec3  ink  = col.a > 0.02 ? (lum > 0.5 ? vec3(0.0) : vec3(1.0)) : vec3(0.5);
    float ga   = line * fade * 0.35;
    float a    = ga + col.a * (1.0 - ga);
    return vec4((ink * ga + col.rgb * col.a * (1.0 - ga)) / max(a, 1e-6), a);
}

void main() {
    uint kind   = v_kind & 0xFFu;
    uint square = (v_kind >> 8u) & 0xFu;
    if (kind == 0u) {
        vec2  half_size = v_rect.zw * 0.5;
        vec2  centre    = v_rect.xy + half_size;
        float r         = clamp(v_params.x, 0.0, min(half_size.x, half_size.y));
        float d         = sd_round_rect_c(v_pos - centre, half_size, r, square);
        float outer     = coverage(d);
        vec4  col       = v_color;
        float bw        = v_params.y;
        if (bw > 0.0) {
            // Inner shape = outer shape shrunk by bw (the SDF offset does this,
            // including the corner radius). Mix in premultiplied space so a
            // transparent fill with an opaque border is composited correctly,
            // then convert back to straight alpha for the blend state.
            float inner   = coverage(d + bw);
            vec3  fill_pm = v_color.rgb * v_color.a;
            vec3  ring_pm = v_border.rgb * v_border.a;
            vec3  rgb_pm  = mix(ring_pm, fill_pm, inner);
            float a       = mix(v_border.a, v_color.a, inner);
            col = vec4(rgb_pm / max(a, 1e-6), a);
        }
        out_color = vec4(col.rgb, col.a * outer);
    } else if (kind == 1u) {
        // Glyph coverage blended in linear light reads too thin for dark text
        // on light ground (the swapchain is sRGB, so the blend is linear).
        // Lift the coverage of dark text toward what a perceptual blend gives;
        // light text on dark ground already looks right and is left alone.
        float a   = texture(tex, v_uv).r;
        float lum = dot(v_color.rgb, vec3(0.2126, 0.7152, 0.0722));
        float g   = mix(0.62, 1.0, smoothstep(0.0, 0.35, lum));
        a = pow(a, g);
        out_color = vec4(v_color.rgb, v_color.a * a);
    } else if (kind == 3u) {
        vec2  half_size = v_rect.zw * 0.5;
        vec2  centre    = v_rect.xy + half_size;
        vec2  p         = v_pos - centre;
        uint  corner    = p.x < 0.0 ? (p.y < 0.0 ? 0u : 3u) : (p.y < 0.0 ? 1u : 2u);
        float r         = ((square >> corner) & 1u) != 0u ? 0.0 : clamp(v_params.x, 0.0, min(half_size.x, half_size.y));
        float a         = shadow_rounded_rect(p, half_size, r, max(v_params.y * 0.5, 0.25));
        if (v_border.z > 0.0) {
            vec2  hh = v_border.zw * 0.5;
            float hr = clamp(v_params.x, 0.0, min(hh.x, hh.y));
            a *= 1.0 - coverage(sd_round_rect_c(v_pos - (v_border.xy + hh), hh, hr, square));
        }
        out_color = vec4(v_color.rgb, v_color.a * a);
    } else if (kind == 4u) {
        vec2  half_size = v_rect.zw * 0.5;
        vec2  centre    = v_rect.xy + half_size;
        float r         = clamp(v_params.x, 0.0, min(half_size.x, half_size.y));
        float cov       = coverage(sd_round_rect_c(v_pos - centre, half_size, r, square));
        // The blurred scene is premultiplied. On an opaque target it is all
        // opaque; on a transparent one (a popup, a glass bar) little or none
        // of it is, and the tint then lets the compositor's blur show through.
        vec4  s         = texture(tex, v_uv);
        vec3  b         = s.a > 0.0 ? s.rgb / s.a : vec3(0.0);
        float lum       = dot(b, vec3(0.2126, 0.7152, 0.0722));
        b = mix(vec3(lum), b, v_border.x);          // saturation (1 = unchanged)
        float a = v_color.a + s.a * (1.0 - v_color.a); // tint over it
        b = (v_color.rgb * v_color.a + b * s.a * (1.0 - v_color.a)) / max(a, 1e-6);
        // Grain hides banding. Scaled by sqrt(luminance) so it is about the
        // same fraction of an sRGB step everywhere: a flat amount reads as
        // static on dark surfaces (linear space is very compressed there).
        float n = fract(sin(dot(floor(v_pos), vec2(12.9898, 78.233))) * 43758.5453) - 0.5;
        b += n * v_border.y * sqrt(max(b, vec3(0.0)));
        out_color = vec4(b, a * cov * (1.0 - v_border.z));
    } else if (kind == 5u) {
        // a picture: texture × tint, corners cut like a quad
        vec2  half_size = v_rect.zw * 0.5;
        vec2  centre    = v_rect.xy + half_size;
        float r         = clamp(v_params.x, 0.0, min(half_size.x, half_size.y));
        float cov       = coverage(sd_round_rect_c(v_pos - centre, half_size, r, square));
        uint  mode      = ((v_kind >> 12u) & 1u) != 0u ? 2u : (((v_kind >> 16u) & 1u) != 0u ? 1u : 0u);
        vec4  t         = picture(v_uv, mode);
        if (((v_kind >> 13u) & 1u) != 0u) t.rgb = canvas_decode(t.rgb, (v_kind >> 14u) & 3u);
        // after the decode, so the grid's ink is not read as canvas values
        if (((v_kind >> 17u) & 1u) != 0u) t = pixel_grid(t, v_uv);
        out_color = vec4(t.rgb * v_color.rgb, t.a * v_color.a * cov);
    } else if (kind == 6u) {
        // A glyph's coverage under a Gaussian of sigma = radius / 2 (as CSS
        // drop-shadow blurs): taps spread evenly over three sigmas on a
        // golden-angle spiral, weighted, and turned per pixel so the few
        // taps read as fine grain rather than rings.
        float sigma = max(v_border.z * 0.5, 0.25);
        float reach = 3.0 * sigma;
        float spin  = 6.2831853 * fract(52.9829189 * fract(dot(v_pos, vec2(0.06711056, 0.00583715))));
        float sum   = 0.0;
        float wsum  = 0.0;
        const int TAPS = 48; // 24 leaves a faint speckle at the letters' edges
        for (int i = 0; i < TAPS; i++) {
            float d   = reach * sqrt((float(i) + 0.5) / float(TAPS));
            float ang = float(i) * 2.3999632 + spin;
            vec2  uv  = v_uv + vec2(cos(ang), sin(ang)) * d * v_border.xy;
            vec4  t   = texture(tex, uv);
            float in_box = step(v_rect.x, uv.x) * step(uv.x, v_rect.z) * step(v_rect.y, uv.y) * step(uv.y, v_rect.w);
            float w   = exp(-(d * d) / (2.0 * sigma * sigma));
            sum  += (v_border.w > 0.5 ? t.a : t.r) * in_box * w;
            wsum += w;
        }
        out_color = vec4(v_color.rgb, v_color.a * sum / max(wsum, 1e-6));
    } else if (kind == 8u) {
        // Distance to the segment, then the same 1 px fringe a quad uses: a
        // polyline is drawn as capsules, so joins and ends are round without
        // any geometry for them.
        vec2  a   = v_rect.xy;
        vec2  b   = v_rect.zw;
        vec2  pa  = v_pos - a;
        vec2  ba  = b - a;
        float len2 = max(dot(ba, ba), 1e-6);
        float h   = clamp(dot(pa, ba) / len2, 0.0, 1.0);
        float d   = length(pa - ba * h) - v_params.x;
        if (v_border.x > 0.5) { // flat cap: cut the capsule back to the ends
            float along = dot(pa, ba) / sqrt(len2);
            float run   = sqrt(len2);
            d = max(d, max(-along, along - run));
        }
        float cov = clamp(0.5 - d, 0.0, 1.0);
        out_color = vec4(v_color.rgb, v_color.a * cov);
    } else if (kind == 7u) {
        // the rounded rect less itself moved down by the line's width
        vec2  half_size = v_rect.zw * 0.5;
        vec2  centre    = v_rect.xy + half_size;
        float r         = clamp(v_params.x, 0.0, min(half_size.x, half_size.y));
        float outer     = coverage(sd_round_rect_c(v_pos - centre, half_size, r, square));
        float lower     = coverage(sd_round_rect_c(v_pos - centre - vec2(0.0, v_params.y), half_size, r, square));
        out_color = vec4(v_color.rgb, v_color.a * outer * (1.0 - lower));
    } else {
        vec4 t = texture(tex, v_uv);
        out_color = vec4(t.rgb, t.a * v_color.a);
    }
}
