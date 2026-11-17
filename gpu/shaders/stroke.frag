#version 450
// A stroke segment's coverage, written to every channel and
// combined into the coverage canvas by the pipeline's MAX blending.
//
// A segment of a variable-width stroke is a round cone — two circles and
// their outer tangents — not a capsule: where the width changes the edge
// slopes, and a capsule leaves a step at every point of a tapering stroke.
// The three cases below are the two end caps and the tangent between them.
//
// The CPU reference is baldr/canvas_stroke.odin, and it is the spec: this is
// right only where it agrees, which spikes/stroke_parity checks.
layout(push_constant) uniform Push { vec2 size; } pc;

layout(location = 0) flat in vec4 v_seg;
layout(location = 1) flat in vec2 v_radii;
layout(location = 0) out vec4 out_color;

float dot2(vec2 v) { return dot(v, v); }

float round_cone(vec2 p, vec2 a, vec2 b, float ra, float rb) {
    vec2  ba = b - a;
    float l2 = dot2(ba);
    float rr = ra - rb;
    if (l2 <= 1e-12) return length(p - a) - max(ra, rb); // both ends one point: a disc
    float a2 = l2 - rr * rr;
    float il2 = 1.0 / l2;
    vec2  pa = p - a;
    float y = dot(pa, ba);
    float z = y - l2;
    float x2 = dot2(pa * l2 - ba * y);
    float y2 = y * y * l2;
    float z2 = z * z * l2;
    float k = sign(rr) * rr * rr * x2;
    if (sign(z) * a2 * z2 > k) return sqrt(x2 + z2) * il2 - rb;
    if (sign(y) * a2 * y2 < k) return sqrt(x2 + y2) * il2 - ra;
    return (sqrt(max(x2 * a2 * il2, 0.0)) + y * rr) * il2 - ra;
}

void main() {
    float d = round_cone(gl_FragCoord.xy, v_seg.xy, v_seg.zw, v_radii.x, v_radii.y);
    float cov = clamp(0.5 - d, 0.0, 1.0); // soft over one texel, as a hard dab's edge is
    out_color = vec4(cov);
}
