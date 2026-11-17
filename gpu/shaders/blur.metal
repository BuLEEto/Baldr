// blur.metal — the Metal port of fullscreen.vert + kawase.frag.
//
// One Kawase pass averages four diagonal taps `offset + 0.5` texels away.
// Ping-ponged a few times with growing offsets it approximates a Gaussian at
// a fraction of the cost. The first pass is a
// plain copy into a quarter-size target, which is the downsample.

#include <metal_stdlib>
using namespace metal;

struct FS_Out {
    float4 position [[position]];
    float2 uv;
};

// A full-screen triangle from the vertex id alone: no buffer, no geometry.
vertex FS_Out fs_main(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);   // (0,0) (2,0) (0,2)
    FS_Out o;
    o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    // Metal's NDC has y up and its texture origin is top-left, so the uv is
    // flipped against the position — the same flip ui.metal's vertex shader
    // makes, for the same reason.
    o.uv = float2(p.x, 1.0 - p.y);
    return o;
}

struct Kawase {
    float2 texel;
    float  offset;
    float  pad;
};

fragment float4 kawase_main(FS_Out in [[stage_in]],
                            texture2d<float> tex [[texture(0)]],
                            sampler samp [[sampler(0)]],
                            constant Kawase &pc [[buffer(0)]]) {
    float2 o = (pc.offset + 0.5) * pc.texel;
    float4 c = tex.sample(samp, in.uv + float2( o.x,  o.y))
             + tex.sample(samp, in.uv + float2(-o.x,  o.y))
             + tex.sample(samp, in.uv + float2( o.x, -o.y))
             + tex.sample(samp, in.uv + float2(-o.x, -o.y));
    return c * 0.25;
}

// The downsample: a straight copy, relying on the smaller target and a linear
// sampler to do the filtering.
fragment float4 copy_main(FS_Out in [[stage_in]],
                          texture2d<float> tex [[texture(0)]],
                          sampler samp [[sampler(0)]]) {
    return tex.sample(samp, in.uv);
}
