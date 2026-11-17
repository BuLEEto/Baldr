#+build darwin
package main

// Baldr's real draw commands, through Baldr's real batcher, rendered by
// Metal — and checked by reading the pixels back.
//
// metal_triangle checks the chain (device, layer, shader, drawable); this
// checks the renderer: `gpu.build_batches` turns a `[]gpu.Cmd` into the same
// `gpu.Vertex` list the Vulkan backend uploads, and an MSL port of ui.vert +
// the KIND_QUAD branch of ui.frag draws it. Nothing here reimplements
// Baldr's geometry or its SDF, so if the two shaders disagree it shows here.
//
// What it checks, by reading a texture rather than looking at a window:
//   - the vertex format crosses unchanged (80 bytes, same field order)
//   - Metal's NDC has y up where Vulkan's has y down, so the port needs a
//     flip the GLSL does not. Without it everything draws upside down, which
//     a round shape on a dark background hides well.
//   - the rounded-rect SDF, the 1 px coverage fringe and the border ring give
//     the same pixels the GLSL describes

import MTL "vendor:darwin/Metal"
import NS "vendor:darwin/AppKit"
import "core:fmt"
import "core:os"
import "baldr:gpu"

W :: 200
H :: 120

// ui.vert and the KIND_QUAD branch of ui.frag, in MSL. The names and the
// maths are deliberately the GLSL's, so the two can be read side by side.
SHADER :: `
#include <metal_stdlib>
using namespace metal;

// gpu.Vertex, 80 bytes, field for field.
//
// **packed_, not plain.** MSL aligns float4 to 16 bytes, so a plain float4
// after two floats is pushed to the next multiple of 16 — this struct would
// be 96 bytes with padding before the border field, against Odin's 80, and every
// vertex after the first would be read from the wrong offset. Nothing draws
// and nothing says why. The packed_ types are 4-byte aligned and lay out
// exactly as Odin's do.
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
    // Vulkan's NDC has y down and matches the pixel space; Metal's has y up.
    ndc.y = -ndc.y;
    V_Out o;
    o.position = float4(ndc, 0.0, 1.0);
    o.v_pos    = v.pos;
    o.v_color  = v.color;
    o.v_rect   = v.rect;
    o.v_params = float2(v.radius, v.border_w);
    o.v_border = v.border;
    o.v_kind   = v.kind;
    return o;
}

// ui.frag's sd_round_rect / sd_round_rect_c / coverage, unchanged.
static float sd_round_rect(float2 p, float2 half_size, float r) {
    float2 q = abs(p) - half_size + r;
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
}

static float sd_round_rect_c(float2 p, float2 half_size, float r, uint square) {
    uint corner = p.x < 0.0 ? (p.y < 0.0 ? 0u : 3u) : (p.y < 0.0 ? 1u : 2u);
    return sd_round_rect(p, half_size, ((square >> corner) & 1u) != 0u ? 0.0 : r);
}

static float coverage(float d) { return clamp(0.5 - d, 0.0, 1.0); }

fragment float4 f_main(V_Out in [[stage_in]]) {
    uint kind   = in.v_kind & 0xFFu;
    uint square = (in.v_kind >> 8u) & 0xFu;
    if (kind != 0u) return float4(1.0, 0.0, 1.0, 1.0); // unported kind: loud magenta

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
`

main :: proc() {
	pool := NS.AutoreleasePool.alloc()->init()
	defer pool->drain()

	// --- Baldr's own commands, through Baldr's own batcher.
	// A zero Renderer: build_batches touches no device state, which is what
	// makes it the half both backends share.
	r: gpu.Renderer
	defer delete(r.verts)
	defer delete(r.batches)

	cmds := []gpu.Cmd{
		// a plain fill, no radius
		gpu.Quad{rect = {10, 10, 60, 40}, color = {0.95, 0.25, 0.25, 1}},
		// rounded, with a thick border: exercises the SDF offset and the ring
		gpu.Quad{rect = {90, 10, 100, 100}, color = {0.15, 0.55, 0.95, 1}, radius = 24, border_w = 6, border = {1, 1, 1, 1}},
		// rounded with two square corners: exercises the `square` bits
		gpu.Quad{rect = {10, 62, 60, 48}, color = {0.25, 0.85, 0.45, 1}, radius = 16, square = {.Top_Left, .Bottom_Right}},
	}
	gpu.build_batches(&r, cmds, {W, H})
	fmt.printfln("batcher: %d vertices in %d batches from %d commands", len(r.verts), len(r.batches), len(cmds))
	for b, i in r.batches do fmt.printfln("  batch %d: kind=%v first=%d count=%d scissor=%v", i, b.kind, b.first, b.count, b.scissor)
	fmt.printfln("  Odin gpu.Vertex is %d bytes", size_of(gpu.Vertex))
	if len(r.verts) == 0 { fmt.eprintln("no vertices"); os.exit(1) }

	// --- Metal
	dev := MTL.CreateSystemDefaultDevice()
	if dev == nil { fmt.eprintln("no Metal device"); os.exit(1) }
	defer dev->release()
	queue := dev->newCommandQueue()
	defer queue->release()

	src := NS.String.alloc()->initWithOdinString(SHADER)
	opts := MTL.CompileOptions.alloc()->init()
	defer opts->release()
	lib, lib_err := dev->newLibraryWithSource(src, opts)
	if lib == nil {
		msg := lib_err != nil ? string(lib_err->localizedDescription()->odinString()) : "?"
		fmt.eprintfln("shader: %s", msg)
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
	// Baldr blends straight alpha over the target, as the Vulkan pipeline does.
	att->setBlendingEnabled(true)
	att->setSourceRGBBlendFactor(.SourceAlpha)
	att->setDestinationRGBBlendFactor(.OneMinusSourceAlpha)
	att->setSourceAlphaBlendFactor(.One)
	att->setDestinationAlphaBlendFactor(.OneMinusSourceAlpha)

	pipeline, pipe_err := dev->newRenderPipelineStateWithDescriptor(desc)
	if pipeline == nil {
		msg := pipe_err != nil ? string(pipe_err->localizedDescription()->odinString()) : "?"
		fmt.eprintfln("pipeline: %s", msg)
		os.exit(1)
	}
	defer pipeline->release()

	vbuf := dev->newBufferWithSlice(r.verts[:], {}) // {} is StorageModeShared
	defer vbuf->release()
	viewport := [2]f32{W, H}

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
	colour->setClearColor(MTL.ClearColor{0, 0, 0, 1})

	cmd := queue->commandBuffer()
	enc := cmd->renderCommandEncoderWithDescriptor(pass)
	enc->setRenderPipelineState(pipeline)
	enc->setVertexBuffer(vbuf, 0, 0)
	enc->setVertexBytes(([^]byte)(&viewport)[:size_of(viewport)], 1)
	for b in r.batches {
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
	defer delete(px)
	tex->getBytes(raw_data(px), W * 4, MTL.Region{{0, 0, 0}, {W, H, 1}}, 0)
	check(px)

	// and a picture of it, so a person can look at what the numbers assert
	if len(os.args) > 1 {
		if err := os.write_entire_file(os.args[1], px); err == nil { // BGRA, W x H
			fmt.printfln("wrote %dx%d BGRA to %s", W, H, os.args[1])
		}
	}
}

at :: proc(px: []u8, x, y: int) -> (r, g, b: int) {
	i := (y * W + x) * 4
	return int(px[i + 2]), int(px[i + 1]), int(px[i + 0]) // BGRA
}

near :: proc(got, want, slack: int) -> bool { return got >= want - slack && got <= want + slack }

check :: proc(px: []u8) {
	ok := true
	say :: proc(name: string, pass: bool, r, g, b: int, ok: ^bool) {
		fmt.printfln("  %-46s rgb(%3d,%3d,%3d)  %s", name, r, g, b, pass ? "ok" : "WRONG")
		if !pass do ok^ = false
	}
	fmt.println("pixels:")

	// the plain red fill, well inside it
	r1, g1, b1 := at(px, 40, 30)
	say("plain quad is its fill colour", near(r1, 242, 6) && near(g1, 64, 6) && near(b1, 64, 6), r1, g1, b1, &ok)

	// the blue rounded rect: inside the border ring, which is white
	r2, g2, b2 := at(px, 140, 13)
	say("border ring is the border colour", near(r2, 255, 10) && near(g2, 255, 10) && near(b2, 255, 10), r2, g2, b2, &ok)

	// …and its fill, well inside the ring
	r3, g3, b3 := at(px, 140, 60)
	say("rounded quad is its fill colour", near(r3, 38, 8) && near(g3, 140, 8) && near(b3, 242, 8), r3, g3, b3, &ok)

	// the rounded corner is *outside* the shape: still the clear colour
	r4, g4, b4 := at(px, 92, 12)
	say("a rounded corner is cut away", r4 < 40 && g4 < 40 && b4 < 40, r4, g4, b4, &ok)

	// the green rect's top-left corner is square, so it IS covered…
	r5, g5, b5 := at(px, 12, 64)
	say("a square corner stays filled", near(r5, 64, 10) && near(g5, 217, 12) && near(b5, 115, 12), r5, g5, b5, &ok)

	// …while its top-right corner is rounded, so it is not
	r6, g6, b6 := at(px, 68, 64)
	say("the other corner is still rounded", r6 < 40 && g6 < 40 && b6 < 40, r6, g6, b6, &ok)

	// the y-flip: the red quad sits in the TOP half in Baldr's
	// coordinates. If the NDC flip were missing it would land at the bottom.
	rt, gt, _ := at(px, 40, 30)
	rb, gb, _ := at(px, 40, 95)
	say("y is not flipped (red is top, not bottom)", rt > 200 && gt < 120 && !(rb > 200 && gb < 120), rt, gt, 0, &ok)

	fmt.printfln("%s", ok ? "ALL PIXELS AS THE GLSL DESCRIBES" : "*** the Metal port disagrees with the GLSL ***")
	if !ok do os.exit(1)
}
