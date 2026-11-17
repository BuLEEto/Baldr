// Baldr canvas blend maths, shared by blend.frag (a source laid on a
// backdrop) and transform.frag (a source sampled through a matrix, then
// laid on the same way). Every formula here has its twin in
// baldr/canvas_blend.odin, the CPU reference the tests check; change one,
// change all three.
#ifndef BALDR_BLEND_COMMON
#define BALDR_BLEND_COMMON

// curves: 0 sRGB's (sRGB, Display P3), 1 Adobe RGB's 2.2, 2 linear
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

float lum(vec3 c) { return 0.3 * c.r + 0.59 * c.g + 0.11 * c.b; }
vec3 clip_color(vec3 c) {
    float l = lum(c);
    float n = min(min(c.r, c.g), c.b);
    float x = max(max(c.r, c.g), c.b);
    if (n < 0.0) c = l + (c - l) * l / (l - n);
    if (x > 1.0) c = l + (c - l) * (1.0 - l) / (x - l);
    return c;
}
vec3 set_lum(vec3 c, float l) { return clip_color(c + (l - lum(c))); }
float sat(vec3 c) { return max(max(c.r, c.g), c.b) - min(min(c.r, c.g), c.b); }
vec3 set_sat(vec3 c, float s) {
    float mx = max(max(c.r, c.g), c.b);
    float mn = min(min(c.r, c.g), c.b);
    return mx > mn ? (c - mn) * s / (mx - mn) : vec3(0.0);
}

float burn(float b, float s)  { return b >= 1.0 ? 1.0 : (s <= 0.0 ? 0.0 : 1.0 - min(1.0, (1.0 - b) / s)); }
float dodge(float b, float s) { return b <= 0.0 ? 0.0 : (s >= 1.0 ? 1.0 : min(1.0, b / (1.0 - s))); }
float soft_d(float b)         { return b <= 0.25 ? ((16.0 * b - 12.0) * b + 4.0) * b : sqrt(b); }

float sep(uint mode, float b, float s) {
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

vec3 blend(uint mode, vec3 b, vec3 s) {
    switch (mode) {
    case 6u:  return s.r + s.g + s.b < b.r + b.g + b.b ? s : b;                   // darker colour
    case 11u: return s.r + s.g + s.b > b.r + b.g + b.b ? s : b;                   // lighter colour
    case 23u: return set_lum(set_sat(s, sat(b)), lum(b));                         // hue
    case 24u: return set_lum(set_sat(b, sat(s)), lum(b));                         // saturation
    case 25u: return set_lum(s, lum(b));                                          // colour
    case 26u: return set_lum(b, lum(s));                                          // luminosity
    }
    return vec3(sep(mode, b.r, s.r), sep(mode, b.g, s.g), sep(mode, b.b, s.b));
}

uint hash(uint v) { // PCG
    uint state = v * 747796405u + 2891336453u;
    uint word  = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}

#endif // BALDR_BLEND_COMMON
