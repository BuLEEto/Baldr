// swap.metal — the MSL twin of swap.frag: input 0's channels swapped (bgra)
// and scaled by a uniform.
//
// The Metal contract (gpu/metal_shader.odin): the destination texel is
// `[[position]].xy`, input i is `[[texture(i)]]`, the push block is
// `[[buffer(0)]]` with Baldr's `int4 area` first and the app's uniforms
// after it, and the entry point is `main0` because MSL reserves `main`.
#include <metal_stdlib>
using namespace metal;

struct P {
    int4  area;
    float scale;
};

fragment float4 main0(float4 pos [[position]],
                      constant P& pc [[buffer(0)]],
                      texture2d<float> photo [[texture(0)]]) {
    float4 v = photo.read(uint2(int2(pos.xy)), 0);
    return float4(v.b * pc.scale, v.g * pc.scale, v.r * pc.scale, v.a);
}
