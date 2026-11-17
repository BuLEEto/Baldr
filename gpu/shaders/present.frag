#version 450
// The present pass of a transparent target (present.odin): its scene, drawn
// and premultiplied in linear light, written as the compositor reads it.
//   mode 0: premultiplied sRGB   rgb = encode(colour) * alpha
//   mode 1: straight             rgb = encode(colour)
//   mode 2: opaque               rgb = encode(colour * alpha), alpha 1
// srgb_target: the swapchain encodes on write, so the value is decoded first.
layout(set = 0, binding = 0) uniform sampler2D tex;
layout(push_constant) uniform PC { uint mode; uint srgb_target; } pc;
layout(location = 0) out vec4 out_color;

vec3 encode(vec3 c) {
    c = clamp(c, 0.0, 1.0);
    return mix(c * 12.92, 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, step(vec3(0.0031308), c));
}

vec3 decode(vec3 c) {
    return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), c));
}

void main() {
    vec4  s      = texelFetch(tex, ivec2(gl_FragCoord.xy), 0); // linear, premultiplied
    vec3  colour = s.a > 0.0 ? s.rgb / s.a : vec3(0.0);
    vec3  rgb    = encode(colour) * s.a;
    float a      = s.a;
    if (pc.mode == 1u) {
        rgb = encode(colour);
    } else if (pc.mode == 2u) {
        rgb = encode(s.rgb);
        a = 1.0;
    }
    out_color = vec4(pc.srgb_target != 0u ? decode(rgb) : rgb, a);
}
