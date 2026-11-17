#+build darwin
package main

// The Metal half: an atlas of textures, a pipeline, and a draw per batch.
// The shaders are ui.vert and the branches of ui.frag the widgets here reach
// — quad, alpha glyph, RGBA glyph and shadow — ported character for
// character, so the two can be read side by side.

import CA "vendor:darwin/QuartzCore"
import "core:mem"
import MTL "vendor:darwin/Metal"
import NS "vendor:darwin/AppKit"
import "core:fmt"
import "core:os"
import "baldr:gpu"

MAX_PAGES :: 16

Renderer :: struct {
	layer:    ^CA.MetalLayer,
	dev:      ^MTL.Device,
	queue:    ^MTL.CommandQueue,
	pipeline: ^MTL.RenderPipelineState,
	sampler:  ^MTL.SamplerState,
	white:    ^MTL.Texture,
	pages:    [MAX_PAGES]^MTL.Texture,
	formats:  [MAX_PAGES]gpu.Page_Format,
	n_pages:  u32,
	batcher:  gpu.Renderer, // zero: build_batches touches no device state
	vbuf:     ^MTL.Buffer,
	vbuf_cap: int,
}

SHADER :: `
#include <metal_stdlib>
using namespace metal;

struct Vertex {                 // gpu.Vertex, 80 bytes; packed_ or the
    packed_float2 pos;          // float4s align to 16 and the layout drifts
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
    float4 v_rect;
    float2 v_params;
    float4 v_border;
    uint   v_kind [[flat]];
};

vertex V_Out v_main(uint vid [[vertex_id]],
                    const device Vertex *verts [[buffer(0)]],
                    constant float2 &viewport [[buffer(1)]]) {
    const device Vertex &v = verts[vid];
    float2 ndc = v.pos / viewport * 2.0 - 1.0;
    ndc.y = -ndc.y;             // Metal NDC is y up; Vulkan's is y down
    V_Out o;
    o.position = float4(ndc, 0.0, 1.0);
    o.v_pos    = v.pos;
    o.v_uv     = v.uv;
    o.v_color  = v.color;
    o.v_rect   = v.rect;
    o.v_params = float2(v.radius, v.border_w);
    o.v_border = v.border;
    o.v_kind   = v.kind;
    return o;
}

static float sd_round_rect(float2 p, float2 half_size, float r) {
    float2 q = abs(p) - half_size + r;
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
}
static float sd_round_rect_c(float2 p, float2 half_size, float r, uint square) {
    uint corner = p.x < 0.0 ? (p.y < 0.0 ? 0u : 3u) : (p.y < 0.0 ? 1u : 2u);
    return sd_round_rect(p, half_size, ((square >> corner) & 1u) != 0u ? 0.0 : r);
}
static float coverage(float d) { return clamp(0.5 - d, 0.0, 1.0); }

// ui.frag's erf2 / gaussian / shadow_x / shadow_rounded_rect, copied rather
// than reconstructed. The first attempt at this was written from the comment
// above them and was wrong in two ways that matter: the integration is
// clamped to +/-3 sigma rather than run over the whole rect, and shadow_x
// takes p.y - y, not y. A guessed port renders a flat band instead of a
// shadow, which looks like a layout bug rather than a shader one.
static float2 erf2(float2 x) {
    float2 s = sign(x), a = abs(x);
    x = 1.0 + (0.278393 + (0.230389 + 0.078108 * (a * a)) * a) * a;
    x *= x;
    return s - s / (x * x);
}
static float gaussian(float x, float sigma) {
    return exp(-(x * x) / (2.0 * sigma * sigma)) / (2.5066282746 * sigma);
}
static float shadow_x(float x, float y, float sigma, float r, float2 half_size) {
    float  delta  = min(half_size.y - r - abs(y), 0.0);
    float  curved = half_size.x - r + sqrt(max(0.0, r * r - delta * delta));
    float2 edge   = 0.5 + 0.5 * erf2((x + float2(-curved, curved)) * (0.70710678 / sigma));
    return edge.y - edge.x;
}
static float shadow_rounded_rect(float2 p, float2 half_size, float r, float sigma) {
    float low   = p.y - half_size.y;
    float high  = p.y + half_size.y;
    float start = clamp(-3.0 * sigma, low, high);
    float end   = clamp(3.0 * sigma, low, high);
    float step  = (end - start) / 4.0;
    float y     = start + step * 0.5;
    float a     = 0.0;
    for (int i = 0; i < 4; i++) {
        a += shadow_x(p.x, p.y - y, sigma, r, half_size) * gaussian(y, sigma) * step;
        y += step;
    }
    return a;
}

fragment float4 f_main(V_Out in [[stage_in]],
                       texture2d<float> tex [[texture(0)]],
                       sampler samp [[sampler(0)]]) {
    uint kind   = in.v_kind & 0xFFu;
    uint square = (in.v_kind >> 8u) & 0xFu;

    if (kind == 0u) {                                   // KIND_QUAD
        float2 half_size = in.v_rect.zw * 0.5;
        float2 centre    = in.v_rect.xy + half_size;
        float  r         = clamp(in.v_params.x, 0.0, min(half_size.x, half_size.y));
        float  d         = sd_round_rect_c(in.v_pos - centre, half_size, r, square);
        float  outer     = coverage(d);
        float4 col       = in.v_color;
        float  bw        = in.v_params.y;
        if (bw > 0.0) {
            float  inner   = coverage(d + bw);
            float3 fill_pm = in.v_color.rgb * in.v_color.a;
            float3 ring_pm = in.v_border.rgb * in.v_border.a;
            float3 rgb_pm  = mix(ring_pm, fill_pm, inner);
            float  a       = mix(in.v_border.a, in.v_color.a, inner);
            col = float4(rgb_pm / max(a, 1e-6), a);
        }
        return float4(col.rgb, col.a * outer);
    }
    if (kind == 1u) {                                   // KIND_ALPHA_GLYPH
        float a   = tex.sample(samp, in.v_uv).r;
        float lum = dot(in.v_color.rgb, float3(0.2126, 0.7152, 0.0722));
        float g   = mix(0.62, 1.0, smoothstep(0.0, 0.35, lum));
        a = pow(a, g);
        return float4(in.v_color.rgb, in.v_color.a * a);
    }
    if (kind == 2u) {                                   // KIND_RGBA_GLYPH
        float4 t = tex.sample(samp, in.v_uv);
        return float4(t.rgb, t.a * in.v_color.a);
    }
    if (kind == 3u) {                                   // KIND_SHADOW
        float2 half_size = in.v_rect.zw * 0.5;
        float2 centre    = in.v_rect.xy + half_size;
        float2 p         = in.v_pos - centre;
        uint   corner    = p.x < 0.0 ? (p.y < 0.0 ? 0u : 3u) : (p.y < 0.0 ? 1u : 2u);
        float  r         = ((square >> corner) & 1u) != 0u ? 0.0 : clamp(in.v_params.x, 0.0, min(half_size.x, half_size.y));
        float  a         = shadow_rounded_rect(p, half_size, r, max(in.v_params.y * 0.5, 0.25));
        if (in.v_border.z > 0.0) {
            float2 hh = in.v_border.zw * 0.5;
            float  hr = clamp(in.v_params.x, 0.0, min(hh.x, hh.y));
            a *= 1.0 - coverage(sd_round_rect_c(in.v_pos - (in.v_border.xy + hh), hh, hr, square));
        }
        return float4(in.v_color.rgb, in.v_color.a * a);
    }
    return float4(1.0, 0.0, 1.0, 0.6);                  // unported kind: visible, not fatal
}
`

renderer_make :: proc(layer: ^CA.MetalLayer) -> (r: Renderer) {
	r.layer = layer
	r.dev = MTL.CreateSystemDefaultDevice()
	if r.dev == nil { fmt.eprintln("no Metal device"); os.exit(1) }
	layer->setDevice(r.dev)
	r.queue = r.dev->newCommandQueue()

	src := NS.String.alloc()->initWithOdinString(SHADER)
	opts := MTL.CompileOptions.alloc()->init()
	defer opts->release()
	lib, err := r.dev->newLibraryWithSource(src, opts)
	if lib == nil {
		fmt.eprintfln("shader: %s", err != nil ? string(err->localizedDescription()->odinString()) : "?")
		os.exit(1)
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
	pipe, perr := r.dev->newRenderPipelineStateWithDescriptor(desc)
	if pipe == nil {
		fmt.eprintfln("pipeline: %s", perr != nil ? string(perr->localizedDescription()->odinString()) : "?")
		os.exit(1)
	}
	r.pipeline = pipe

	sd := MTL.SamplerDescriptor.alloc()->init()
	defer sd->release()
	sd->setMinFilter(.Linear)
	sd->setMagFilter(.Linear)
	r.sampler = r.dev->newSamplerStateWithDescriptor(sd)

	// The white page: what a quad samples, and the fallback for an unknown
	// page, exactly as gpu's WHITE_PAGE is.
	td := MTL.TextureDescriptor.alloc()->init()
	defer td->release()
	td->setTextureType(._2D)
	td->setPixelFormat(.R8Unorm)
	td->setWidth(1); td->setHeight(1)
	td->setUsage({.ShaderRead})
	r.white = r.dev->newTextureWithDescriptor(td)
	ones := [1]u8{255}
	r.white->replaceRegion(MTL.Region{{0, 0, 0}, {1, 1, 1}}, 0, raw_data(ones[:]), 1)
	return
}

renderer_destroy :: proc(r: ^Renderer) {
	for i in 0 ..< r.n_pages do if r.pages[i] != nil do r.pages[i]->release()
	if r.white != nil do r.white->release()
	if r.sampler != nil do r.sampler->release()
	if r.pipeline != nil do r.pipeline->release()
	if r.vbuf != nil do r.vbuf->release()
	if r.queue != nil do r.queue->release()
	if r.dev != nil do r.dev->release()
	delete(r.batcher.verts)
	delete(r.batcher.batches)
}

// --- the atlas sink Baldr fills

atlas_create :: proc(user: rawptr, format: gpu.Page_Format, size: [2]u32) -> gpu.Page {
	r := (^Renderer)(user)
	if r.n_pages >= MAX_PAGES do return 0
	td := MTL.TextureDescriptor.alloc()->init()
	defer td->release()
	td->setTextureType(._2D)
	td->setPixelFormat(format == .RGBA8 ? .RGBA8Unorm : .R8Unorm)
	td->setWidth(NS.UInteger(size.x))
	td->setHeight(NS.UInteger(size.y))
	td->setUsage({.ShaderRead})
	tex := r.dev->newTextureWithDescriptor(td)
	if tex == nil do return 0
	r.pages[r.n_pages] = tex
	r.formats[r.n_pages] = format
	r.n_pages += 1
	return gpu.Page(r.n_pages) // 1-based: 0 means "no page", as gpu does
}

atlas_upload :: proc(user: rawptr, page: gpu.Page, x, y, w, h: u32, pixels: []u8) {
	r := (^Renderer)(user)
	i := int(page) - 1
	if i < 0 || i >= int(r.n_pages) || r.pages[i] == nil do return
	bpp := u32(r.formats[i] == .RGBA8 ? 4 : 1)
	r.pages[i]->replaceRegion(
		MTL.Region{{NS.UInteger(x), NS.UInteger(y), 0}, {NS.UInteger(w), NS.UInteger(h), 1}},
		0, raw_data(pixels), NS.UInteger(w * bpp))
}

// --- the frame

draw :: proc(r: ^Renderer, cmds: []gpu.Cmd, extent: [2]u32) {
	frame_pool := NS.AutoreleasePool.alloc()->init() // per frame, or Metal's
	defer frame_pool->drain()                        // temporaries pile up

	gpu.build_batches(&r.batcher, cmds, extent)
	verts := r.batcher.verts[:]
	if len(verts) == 0 do return

	if len(verts) > r.vbuf_cap {
		if r.vbuf != nil do r.vbuf->release()
		r.vbuf_cap = max(len(verts) * 2, 4096)
		r.vbuf = r.dev->newBufferWithLength(NS.UInteger(r.vbuf_cap * size_of(gpu.Vertex)), {})
	}
	// contents() is a rawptr, not a slice
	mem.copy(r.vbuf->contents(), raw_data(verts), len(verts) * size_of(gpu.Vertex))

	drawable := r.layer->nextDrawable()
	if drawable == nil do return
	// not released: nextDrawable is autoreleased and the frame pool owns it

	pass := MTL.RenderPassDescriptor.renderPassDescriptor()
	colour := pass->colorAttachments()->object(0)
	colour->setTexture(drawable->texture())
	colour->setLoadAction(.Clear)
	colour->setStoreAction(.Store)
	colour->setClearColor(MTL.ClearColor{0.07, 0.08, 0.10, 1.0})

	viewport := [2]f32{f32(extent.x), f32(extent.y)}
	cmd := r.queue->commandBuffer()
	enc := cmd->renderCommandEncoderWithDescriptor(pass)
	enc->setRenderPipelineState(r.pipeline)
	enc->setVertexBuffer(r.vbuf, 0, 0)
	enc->setVertexBytes(([^]byte)(&viewport)[:size_of([2]f32)], 1)
	enc->setFragmentSamplerState(r.sampler, 0)
	for b in r.batcher.batches {
		if b.kind != .Draw || b.count == 0 do continue
		tex := r.white
		if i := int(b.page) - 1; i >= 0 && i < int(r.n_pages) && r.pages[i] != nil do tex = r.pages[i]
		enc->setFragmentTexture(tex, 0)
		enc->setScissorRect(MTL.ScissorRect{
			NS.UInteger(b.scissor.x), NS.UInteger(b.scissor.y),
			NS.UInteger(b.scissor.w), NS.UInteger(b.scissor.h)})
		enc->drawPrimitives(.Triangle, NS.UInteger(b.first), NS.UInteger(b.count))
	}
	enc->endEncoding()
	cmd->presentDrawable(drawable)
	cmd->commit()
}
