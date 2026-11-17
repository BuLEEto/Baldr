// pattern.metal — the MSL twin of pattern.comp: a pattern written into the
// rectangle from x, y and a uniform level.
//
// The destination is `[[texture(0)]]`, written; the texel comes from
// `[[thread_position_in_grid]]`. Metal dispatches exactly the rectangle
// (dispatchThreads handles a partial threadgroup at the edges), so the
// bounds check the GLSL needs is never true here — kept so the two sources
// read alike, and because a shader should not rely on being dispatched
// exactly.
#include <metal_stdlib>
using namespace metal;

struct P {
    int4  area;
    float level;
};

kernel void main0(uint2 gid [[thread_position_in_grid]],
                  constant P& pc [[buffer(0)]],
                  texture2d<float, access::write> dst [[texture(0)]]) {
    int2 i = int2(gid);
    if (i.x >= pc.area.z || i.y >= pc.area.w) return;
    int2 p = pc.area.xy + i;
    dst.write(float4(float(i.x) / 255.0, float(i.y) / 255.0, pc.level, 1.0), uint2(p));
}
