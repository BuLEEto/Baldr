// diff.metal — the MSL twin of diff.frag: a blend of the app's own,
// |source − backdrop| squared, opaque. The backdrop is the texture after
// the inputs, read at texel − the rectangle's origin.
#include <metal_stdlib>
using namespace metal;

struct P {
    int4 area;
};

fragment float4 main0(float4 pos [[position]],
                      constant P& pc [[buffer(0)]],
                      texture2d<float> src      [[texture(0)]],
                      texture2d<float> backdrop [[texture(1)]]) {
    int2   p = int2(pos.xy);
    float3 d = src.read(uint2(p), 0).rgb - backdrop.read(uint2(p - pc.area.xy), 0).rgb;
    return float4(d * d, 1.0);
}
