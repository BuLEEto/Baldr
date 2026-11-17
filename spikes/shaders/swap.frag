#version 450
// input 0's channels swapped (bgra) and scaled by a uniform
layout(set = 0, binding = 0) uniform sampler2D photo;
layout(push_constant) uniform P { ivec4 area; float scale; } pc;
layout(location = 0) out vec4 o;
void main() {
    vec4 v = texelFetch(photo, ivec2(gl_FragCoord.xy), 0);
    o = vec4(v.b * pc.scale, v.g * pc.scale, v.r * pc.scale, v.a);
}
