package baldr

// An app's own shaders on canvases: for an effect Baldr has no operation
// for, the app's own fragment or compute shader, run in the same queue as
// Baldr's work on canvases, in the app's order. Canvases in (sampled), a
// canvas out, uniforms, and a fragment shader may read what it draws over.
// The contract a shader is written to is in gpu/shader.odin (Vulkan),
// gpu/metal_shader.odin (Metal) and docs/widgets.md.
//
// An app gives the shader in both forms — SPIR-V, which glslc builds from
// GLSL, and MSL — and shader_create takes the one the running backend can
// compile. A build-time tool makes the pair from one source, so Baldr's
// runtime stays within its dependency rule. The CPU reference cannot run an
// app's shader: there shader_create is false, and an app keeps a CPU path
// of its own if it needs one.

import "baldr:gpu"

// Shader names an app's shader on its Gpu. 0 is none.
Shader :: gpu.Shader

// Shader_Stage: a shader drawn over a rectangle (Fragment), or dispatched
// over it (Compute).
Shader_Stage :: gpu.Shader_Stage

// Shader_Code is one shader for each backend: `spirv` for Vulkan, `msl`
// for Metal, and `entry` for the MSL entry point's name — empty means
// `main0`, which is what spirv-cross emits because MSL reserves `main`.
Shader_Code :: gpu.Shader_Code

// shader_create makes a shader of `stage` from `code`, reading `inputs`
// canvases (at most 6) and, for a fragment shader with `backdrop`, a copy
// of the rectangle it draws over. False on the CPU reference, when `code`
// carries nothing the running backend can compile, when what it carries is
// not of that stage (on Vulkan a compute shader must also declare its local
// size; on Metal the pipeline decides it), or when the device refuses it.
// The caller's: shader_destroy.
//
//	code := Shader_Code{
//		spirv = #load("vignette.frag.spv", []u32), // Vulkan
//		msl   = #load("vignette.metal", string),   // Metal
//	}
//	s.vignette, _ = baldr.shader_create(g, .Fragment, code, inputs = 1)
shader_create :: proc(g: Gpu, stage: Shader_Stage, code: Shader_Code, inputs: int, backdrop := false) -> (s: Shader, ok: bool) {
	h := g.host
	if h == nil || h.r == nil do return
	s = gpu.shader_create(h.r, stage, code, inputs, backdrop)
	return s, s != 0
}

// shader_destroy frees a shader once the work queued before it is done.
shader_destroy :: proc(g: Gpu, s: Shader) {
	if g.host != nil && g.host.r != nil do gpu.shader_destroy(g.host.r, s)
}

// canvas_shader runs shader `s` over the rectangle of `dst`, reading
// `inputs` (as many as the shader was made for; not `dst`) and given
// `uniforms` (at most 112 bytes, after Baldr's 16: see the contract).
// False for no such shader or canvas, the wrong number of inputs, a
// rectangle outside `dst`, a compute shader's destination whose format it
// cannot write (gpu_limits().storage), or the CPU reference.
//
//	Look :: struct { strength: f32, centre: [2]f32 }
//	look := Look{0.6, {512, 384}}
//	baldr.canvas_shader(g, s.vignette, layer, 0, 0, w, h, {photo}, mem.ptr_to_bytes(&look))
canvas_shader :: proc(g: Gpu, s: Shader, dst: Canvas, x, y, w, h: int, inputs: []Canvas = nil, uniforms: []u8 = nil) -> bool {
	d := canvas_entry(g, dst)
	if d == nil || g.host.r == nil || !canvas_rect_ok(d, x, y, w, h) || len(inputs) > gpu.SHADER_INPUTS do return false
	pages: [gpu.SHADER_INPUTS]gpu.Page
	for c, i in inputs {
		e := canvas_entry(g, c)
		if e == nil do return false
		pages[i] = e.page
	}
	if !gpu.canvas_shader(g.host.r, s, d.page, u32(x), u32(y), u32(w), u32(h), pages[:len(inputs)], uniforms) do return false
	d.version += 1
	return true
}
