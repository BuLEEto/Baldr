#version 450
// One Kawase blur pass: average four diagonal taps `offset + 0.5` texels
// away. Ping-ponged a few times with growing offsets it approximates a
// Gaussian at a fraction of the cost.
layout(location = 0) in vec2 v_uv;
layout(set = 0, binding = 0) uniform sampler2D tex;
layout(push_constant) uniform PC { vec2 texel; float offset; float pad; } pc;
layout(location = 0) out vec4 out_color;
void main() {
    vec2 o = (pc.offset + 0.5) * pc.texel;
    vec4 c = texture(tex, v_uv + vec2( o.x,  o.y)) + texture(tex, v_uv + vec2(-o.x,  o.y))
           + texture(tex, v_uv + vec2( o.x, -o.y)) + texture(tex, v_uv + vec2(-o.x, -o.y));
    out_color = c * 0.25;
}
