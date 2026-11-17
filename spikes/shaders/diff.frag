#version 450
// a blend of the app's own: |source - backdrop|, squared, opaque
layout(set = 0, binding = 0) uniform sampler2D src;
layout(set = 1, binding = 0) uniform sampler2D backdrop;
layout(push_constant) uniform P { ivec4 area; } pc;
layout(location = 0) out vec4 o;
void main() {
    ivec2 p = ivec2(gl_FragCoord.xy);
    vec3 d = texelFetch(src, p, 0).rgb - texelFetch(backdrop, p - pc.area.xy, 0).rgb;
    o = vec4(d * d, 1.0);
}
