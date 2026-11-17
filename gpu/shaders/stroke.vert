#version 450
// Baldr variable-width strokes: one quad per segment, over the
// part of the coverage canvas that segment can touch. stroke.frag works out
// the coverage; the pipeline's MAX blending makes the stroke's segments a
// union rather than a build-up, so joins and self-crossings do not darken.
layout(location = 0) in vec2 a_pos;   // texel coords of this corner
layout(location = 1) in vec4 a_seg;   // the segment: a.xy, b.xy
layout(location = 2) in vec2 a_radii; // its radius at each end

layout(push_constant) uniform Push { vec2 size; } pc; // the canvas's size

layout(location = 0) flat out vec4 v_seg;
layout(location = 1) flat out vec2 v_radii;

void main() {
    v_seg = a_seg;
    v_radii = a_radii;
    gl_Position = vec4(a_pos / pc.size * 2.0 - 1.0, 0.0, 1.0);
}
