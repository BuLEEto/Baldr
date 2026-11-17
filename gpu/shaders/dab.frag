#version 450
// A brush dab's coverage, written to every channel
// and laid onto the stroke canvas by the pipeline's blending (ONE,
// ONE_MINUS_SRC_ALPHA): coverage = old + dab × (1 − old), dab after dab
// in the order given. Round tips: solid out to hardness × radius, then a
// smooth falloff to the rim (a hard tip is anti-aliased over a texel).
// A tip texture: its first channel, the dab's square turned by its angle.
// The CPU reference is baldr/canvas_brush.odin.
layout(set = 0, binding = 0) uniform sampler2D tip_tex;
layout(push_constant) uniform Push { vec2 size; uint tip; } pc;

layout(location = 0) in vec2 v_pos;
layout(location = 1) flat in vec2 v_centre;
layout(location = 2) flat in vec4 v_dab;
layout(location = 0) out vec4 out_color;

void main() {
    float r = v_dab.x;
    float hard = clamp(v_dab.y, 0.0, 1.0);
    vec2  d = gl_FragCoord.xy - v_centre;
    float cov;
    if (pc.tip != 0u) {
        float c = cos(v_dab.w), s = sin(v_dab.w);
        vec2  q = vec2(c * d.x + s * d.y, -s * d.x + c * d.y) / (2.0 * r) + 0.5;
        cov = (q.x < 0.0 || q.y < 0.0 || q.x > 1.0 || q.y > 1.0) ? 0.0 : textureLod(tip_tex, q, 0.0).r;
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
    out_color = vec4(clamp(cov * v_dab.z, 0.0, 1.0));
}
