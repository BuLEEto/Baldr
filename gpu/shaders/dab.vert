#version 450
// Baldr brush dabs: one quad per dab over the part
// of the stroke canvas it can touch; dab.frag works out its coverage.
layout(location = 0) in vec2 a_pos;    // texel coords of this corner
layout(location = 1) in vec2 a_centre; // the dab's centre
layout(location = 2) in vec4 a_dab;    // radius, hardness, strength, angle

layout(push_constant) uniform Push { vec2 size; uint tip; } pc; // the canvas's size; 1: sample the tip texture

layout(location = 0) out vec2 v_pos;
layout(location = 1) flat out vec2 v_centre;
layout(location = 2) flat out vec4 v_dab;

void main() {
    v_pos = a_pos;
    v_centre = a_centre;
    v_dab = a_dab;
    gl_Position = vec4(a_pos / pc.size * 2.0 - 1.0, 0.0, 1.0);
}
