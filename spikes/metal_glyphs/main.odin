#+build darwin
package main

// Glyphs through Metal: a texture, a sampler, and the perceptual coverage
// lift that makes dark text read correctly on a light ground.
//
// metal_quads covers the vertex seam with one untextured kind; this adds
// the part text depends on. ui.frag's KIND_ALPHA_GLYPH does not simply
// multiply coverage by colour:
//
//     float a   = texture(tex, v_uv).r;
//     float lum = dot(v_color.rgb, vec3(0.2126, 0.7152, 0.0722));
//     float g   = mix(0.62, 1.0, smoothstep(0.0, 0.35, lum));
//     a = pow(a, g);
//
// because the swapchain is sRGB, so blending happens in linear light and
// dark text on a light ground otherwise reads too thin. Light text is left
// alone. A wrong exponent breaks nothing visibly; it makes text slightly
// wrong everywhere.
//
// The expected values below are worked out from the GLSL by hand, not from
// this port, so the check is independent of the thing it checks.

import MTL "vendor:darwin/Metal"
import NS "vendor:darwin/AppKit"
import "core:fmt"
import "core:os"
import "baldr:gpu"

W :: 64
H :: 32

SHADER :: `
#include <metal_stdlib>
using namespace metal;

struct Vertex {
    packed_float2 pos;
    packed_float2 uv;
    packed_float4 color;
    packed_float4 rect;
    float         radius;
    float         border_w;
    packed_float4 border;
    uint          kind;
    uint          pad;
};

struct V_Out {
    float4 position [[position]];
    float2 v_pos;
    float2 v_uv;
    float4 v_color;
    uint   v_kind [[flat]];
};

vertex V_Out v_main(uint vid [[vertex_id]],
                    const device Vertex *verts [[buffer(0)]],
                    constant float2 &viewport [[buffer(1)]]) {
    const device Vertex &v = verts[vid];
    float2 ndc = v.pos / viewport * 2.0 - 1.0;
    ndc.y = -ndc.y;                 // Metal NDC is y up; Vulkan's is y down
    V_Out o;
    o.position = float4(ndc, 0.0, 1.0);
    o.v_pos    = v.pos;
    o.v_uv     = v.uv;
    o.v_color  = v.color;
    o.v_kind   = v.kind;
    return o;
}

fragment float4 f_main(V_Out in [[stage_in]],
                       texture2d<float> tex [[texture(0)]],
                       sampler samp [[sampler(0)]]) {
    uint kind = in.v_kind & 0xFFu;
    if (kind == 1u) {              // KIND_ALPHA_GLYPH, ui.frag character for character
        float a   = tex.sample(samp, in.v_uv).r;
        float lum = dot(in.v_color.rgb, float3(0.2126, 0.7152, 0.0722));
        float g   = mix(0.62, 1.0, smoothstep(0.0, 0.35, lum));
        a = pow(a, g);
        return float4(in.v_color.rgb, in.v_color.a * a);
    }
    return float4(1.0, 0.0, 1.0, 1.0); // unported kind: loud magenta
}
`

main :: proc() {
	pool := NS.AutoreleasePool.alloc()->init()
	defer pool->drain()

	dev := MTL.CreateSystemDefaultDevice()
	if dev == nil { fmt.eprintln("no Metal device"); os.exit(1) }
	defer dev->release()
	queue := dev->newCommandQueue()
	defer queue->release()

	// --- a one-texel "atlas" holding a known coverage: 128/255 = 0.501961
	atlas_td := MTL.TextureDescriptor.alloc()->init()
	defer atlas_td->release()
	atlas_td->setTextureType(._2D)
	atlas_td->setPixelFormat(.R8Unorm) // an Alpha8 page, as gpu.Page_Format.Alpha8
	atlas_td->setWidth(1)
	atlas_td->setHeight(1)
	atlas_td->setUsage({.ShaderRead})
	atlas := dev->newTextureWithDescriptor(atlas_td)
	defer atlas->release()
	coverage := [1]u8{128}
	atlas->replaceRegion(MTL.Region{{0, 0, 0}, {1, 1, 1}}, 0, raw_data(coverage[:]), 1)

	sd := MTL.SamplerDescriptor.alloc()->init()
	defer sd->release()
	sd->setMinFilter(.Linear)
	sd->setMagFilter(.Linear)
	samp := dev->newSamplerStateWithDescriptor(sd)
	defer samp->release()

	// --- Baldr's own commands. A zero Renderer has no page table, so the
	// batcher falls back to the white page and KIND_ALPHA_GLYPH, which is
	// the kind under test; the uv the command carries is kept either way,
	// and the texture bound below is what the batch's page resolves to.
	r: gpu.Renderer
	defer delete(r.verts)
	defer delete(r.batches)
	cmds := []gpu.Cmd{
		// dark text, the case the lift exists for
		gpu.Glyph{rect = {4, 4, 24, 24}, uv = {0.5, 0.5, 0.5, 0.5}, color = {0.1, 0.1, 0.1, 1}},
		// light text, which the lift leaves alone
		gpu.Glyph{rect = {36, 4, 24, 24}, uv = {0.5, 0.5, 0.5, 0.5}, color = {0.9, 0.9, 0.9, 1}},
	}
	gpu.build_batches(&r, cmds, {W, H})
	fmt.printfln("batcher: %d vertices, %d batches", len(r.verts), len(r.batches))
	if len(r.verts) == 0 { fmt.eprintln("no vertices"); os.exit(1) }

	src := NS.String.alloc()->initWithOdinString(SHADER)
	opts := MTL.CompileOptions.alloc()->init()
	defer opts->release()
	lib, lib_err := dev->newLibraryWithSource(src, opts)
	if lib == nil {
		msg := lib_err != nil ? string(lib_err->localizedDescription()->odinString()) : "?"
		fmt.eprintfln("shader: %s", msg); os.exit(1)
	}
	defer lib->release()
	v_fn := lib->newFunctionWithName(NS.AT("v_main"))
	f_fn := lib->newFunctionWithName(NS.AT("f_main"))
	defer v_fn->release()
	defer f_fn->release()

	desc := MTL.RenderPipelineDescriptor.alloc()->init()
	defer desc->release()
	desc->setVertexFunction(v_fn)
	desc->setFragmentFunction(f_fn)
	att := desc->colorAttachments()->object(0)
	att->setPixelFormat(.BGRA8Unorm)
	att->setBlendingEnabled(true)
	att->setSourceRGBBlendFactor(.SourceAlpha)
	att->setDestinationRGBBlendFactor(.OneMinusSourceAlpha)
	att->setSourceAlphaBlendFactor(.One)
	att->setDestinationAlphaBlendFactor(.OneMinusSourceAlpha)
	pipeline, pipe_err := dev->newRenderPipelineStateWithDescriptor(desc)
	if pipeline == nil {
		msg := pipe_err != nil ? string(pipe_err->localizedDescription()->odinString()) : "?"
		fmt.eprintfln("pipeline: %s", msg); os.exit(1)
	}
	defer pipeline->release()

	vbuf := dev->newBufferWithSlice(r.verts[:], {})
	defer vbuf->release()
	viewport := [2]f32{W, H}

	// Dark text goes over a *white* ground, which is the case the lift is
	// for; light text over black. Two passes, so each has its own clear.
	dark := render(dev, queue, pipeline, vbuf, samp, atlas, &viewport, r.batches[:], {1, 1, 1, 1})
	defer delete(dark)
	light := render(dev, queue, pipeline, vbuf, samp, atlas, &viewport, r.batches[:], {0, 0, 0, 1})
	defer delete(light)

	ok := true
	// Worked from the GLSL by hand, with coverage 128/255 = 0.501961:
	//   dark  lum .1 -> smoothstep(0,.35,.1)=.198251 -> g=.695335
	//                -> a=.501961^.695335=.619306
	//                -> over white: .1*.619306 + 1*(1-.619306) = .442625 -> 113
	//   light lum .9 -> smoothstep=1 -> g=1 -> a=.501961
	//                -> over black: .9*.501961 = .451765 -> 115
	dr, _, _ := at(dark, 16, 16)
	lr, _, _ := at(light, 48, 16)
	say("dark text on white is lifted  (want 113)", dr, 113, &ok)
	say("light text on black is not    (want 115)", lr, 115, &ok)

	// and the lift must actually do something: without it dark text would be
	// .1*.501961 + 1*(1-.501961) = .548235 -> 140, a visibly thinner glyph
	fmt.printfln("  (without the lift dark text would be 140, so the %d above is the lift working)", dr)
	fmt.printfln("%s", ok ? "GLYPH COVERAGE MATCHES THE GLSL" : "*** the glyph port disagrees with the GLSL ***")
	if !ok do os.exit(1)
}

render :: proc(dev: ^MTL.Device, queue: ^MTL.CommandQueue, pipeline: ^MTL.RenderPipelineState,
               vbuf: ^MTL.Buffer, samp: ^MTL.SamplerState, atlas: ^MTL.Texture,
               viewport: ^[2]f32, batches: []gpu.Batch, clear: MTL.ClearColor) -> []u8 {
	td := MTL.TextureDescriptor.alloc()->init()
	defer td->release()
	td->setTextureType(._2D)
	td->setPixelFormat(.BGRA8Unorm)
	td->setWidth(W)
	td->setHeight(H)
	td->setUsage({.RenderTarget, .ShaderRead})
	td->setStorageMode(.Managed)
	tex := dev->newTextureWithDescriptor(td)
	defer tex->release()

	pass := MTL.RenderPassDescriptor.renderPassDescriptor()
	colour := pass->colorAttachments()->object(0)
	colour->setTexture(tex)
	colour->setLoadAction(.Clear)
	colour->setStoreAction(.Store)
	colour->setClearColor(clear)

	cmd := queue->commandBuffer()
	enc := cmd->renderCommandEncoderWithDescriptor(pass)
	enc->setRenderPipelineState(pipeline)
	enc->setVertexBuffer(vbuf, 0, 0)
	enc->setVertexBytes(([^]byte)(viewport)[:size_of([2]f32)], 1)
	enc->setFragmentTexture(atlas, 0)
	enc->setFragmentSamplerState(samp, 0)
	for b in batches {
		if b.kind != .Draw do continue
		enc->setScissorRect(MTL.ScissorRect{NS.UInteger(b.scissor.x), NS.UInteger(b.scissor.y), NS.UInteger(b.scissor.w), NS.UInteger(b.scissor.h)})
		enc->drawPrimitives(.Triangle, NS.UInteger(b.first), NS.UInteger(b.count))
	}
	enc->endEncoding()
	blit := cmd->blitCommandEncoder()
	blit->synchronizeResource(tex)
	blit->endEncoding()
	cmd->commit()
	cmd->waitUntilCompleted()

	px := make([]u8, W * H * 4)
	tex->getBytes(raw_data(px), W * 4, MTL.Region{{0, 0, 0}, {W, H, 1}}, 0)
	return px
}

at :: proc(px: []u8, x, y: int) -> (r, g, b: int) {
	i := (y * W + x) * 4
	return int(px[i + 2]), int(px[i + 1]), int(px[i + 0]) // BGRA
}

say :: proc(name: string, got, want: int, ok: ^bool) {
	pass := got >= want - 2 && got <= want + 2
	fmt.printfln("  %-42s %3d  %s", name, got, pass ? "ok" : "WRONG")
	if !pass do ok^ = false
}
