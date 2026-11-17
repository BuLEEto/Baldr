#+build darwin
// metal_shader.odin — an app's own shaders on canvases, for Metal
// (gpu/shader.odin is the Vulkan half).
//
// Same contract, place in the queue and push block. An app writes MSL rather
// than GLSL compiled to SPIR-V, and Metal binds by index where Vulkan binds
// descriptor sets, so the MSL contract is:
//
// Fragment (shader_create(.Fragment)): drawn over the destination
// rectangle, one invocation a texel, returning `float4` as the texel's
// stored values (straight alpha; no blending). The destination texel is
// `[[position]].xy`, which is `gl_FragCoord.xy` unchanged. Input i is
// `texture2d<float> [[texture(i)]]`; with `backdrop` one more texture,
// after the inputs, holds a copy of the destination rectangle as it was
// (read at texel − rectangle origin), for a shader that blends.
//
// Compute (shader_create(.Compute)): dispatched over the destination
// rectangle, writing it as
// `texture2d<float, access::write> [[texture(0)]]` at any texel (the
// rectangle is where it should), with input i at `[[texture(i + 1)]]` and
// the texel from `[[thread_position_in_grid]]`. A canvas can be a compute
// shader's destination when its format allows it (Limits.storage).
//
// Both: `constant Shader_Push& [[buffer(0)]]` of 128 bytes, the first 16
// Baldr's — `int4 area`: the destination rectangle's x, y, w, h — then the
// app's uniforms (up to 112 bytes, as canvas_shader was given them).
//
// `dispatchThreads` handles a partial threadgroup at the edges, so a compute
// shader runs over exactly the rectangle, with no overspill to ignore as on
// Vulkan. MSL has no `layout(local_size_x)`: the threadgroup size comes from
// the compiled pipeline at dispatch, so a shader cannot fail for want of one.
package gpu

import MTL "vendor:darwin/Metal"
import NS "core:sys/darwin/Foundation"

@(private)
Shader_State :: struct {
	used:      bool,
	stage:     Shader_Stage,
	inputs:    int,
	backdrop:  bool,
	lib:       ^MTL.Library,
	fn:        ^MTL.Function,
	pipelines: [Canvas_Format]^MTL.RenderPipelineState, // a fragment shader's, per destination format
	compute:   ^MTL.ComputePipelineState,
	local:     [2]u32, // the threadgroup size the compute pipeline wants
}

@(private)
Shader_Push :: struct {
	area:     [4]i32,
	uniforms: [SHADER_UNIFORMS]u8,
}
#assert(size_of(Shader_Push) == 128)

// shader_create makes a shader from `code` for `stage`, reading `inputs`
// canvases (at most SHADER_INPUTS) and, for a fragment shader with
// `backdrop`, a copy of what it draws over. 0 when there is no device, the
// code carries no MSL, it does not compile, it has no entry point of that
// name, or that entry point is not of `stage`.
shader_create :: proc(r: ^Renderer, stage: Shader_Stage, code: Shader_Code, inputs: int, backdrop := false) -> Shader {
	if r.dev == nil || inputs < 0 || inputs > SHADER_INPUTS do return 0
	if code.msl == "" {
		r.last_error = "shader_create: Shader_Code carries no MSL, which is what the Metal backend compiles"
		return 0
	}
	src := NS.String.alloc()->initWithOdinString(code.msl)
	opts := MTL.CompileOptions.alloc()->init()
	defer opts->release()
	lib, err := r.dev->newLibraryWithSource(src, opts)
	if lib == nil {
		r.last_error = err != nil ? string(err->localizedDescription()->odinString()) : "shader_create: the MSL did not compile"
		return 0
	}
	// MSL reserves `main`, so spirv-cross names its entry `main0`.
	entry := code.entry if code.entry != "" else "main0"
	fn := lib->newFunctionWithName(NS.String.alloc()->initWithOdinString(entry))
	if fn == nil {
		r.last_error = "shader_create: the MSL has no such entry point"
		lib->release()
		return 0
	}
	want: MTL.FunctionType = stage == .Compute ? .Kernel : .Fragment
	if fn->functionType() != want {
		r.last_error = "shader_create: the entry point is not of the stage asked for"
		fn->release()
		lib->release()
		return 0
	}

	st := Shader_State{
		used     = true,
		stage    = stage,
		inputs   = inputs,
		backdrop = backdrop && stage == .Fragment,
		lib      = lib,
		fn       = fn,
	}
	if stage == .Compute {
		pipe, perr := r.dev->newComputePipelineStateWithFunction(fn)
		if pipe == nil {
			r.last_error = perr != nil ? string(perr->localizedDescription()->odinString()) : "shader_create: compute pipeline"
			shader_state_destroy(r, &st)
			return 0
		}
		st.compute = pipe
		// The threadgroup Apple's own guidance asks for: the execution width
		// across, the rest of the budget down.
		wide := u32(pipe->threadExecutionWidth())
		total := u32(pipe->maxTotalThreadsPerThreadgroup())
		st.local = {max(wide, 1), max(total / max(wide, 1), 1)}
	}
	for &s, i in r.shaders do if !s.used {
		s = st
		return Shader(i + 1)
	}
	append(&r.shaders, st)
	return Shader(len(r.shaders))
}

// shader_destroy frees a shader once the work queued before it is done (it
// waits for the batches in flight).
shader_destroy :: proc(r: ^Renderer, s: Shader) {
	st := shader_state(r, s)
	if st == nil do return
	canvas_idle(r)
	shader_state_destroy(r, st)
}

@(private)
shader_state :: proc(r: ^Renderer, s: Shader) -> ^Shader_State {
	i := int(s) - 1
	if i < 0 || i >= len(r.shaders) || !r.shaders[i].used do return nil
	return &r.shaders[i]
}

@(private)
shader_state_destroy :: proc(r: ^Renderer, st: ^Shader_State) {
	for p in st.pipelines do if p != nil do p->release()
	if st.compute != nil do st.compute->release()
	if st.fn != nil do st.fn->release()
	if st.lib != nil do st.lib->release()
	st^ = {}
}

@(private)
shader_shutdown :: proc(r: ^Renderer) {
	for &st in r.shaders do if st.used do shader_state_destroy(r, &st)
	delete(r.shaders)
	r.shaders = nil
}

// canvas_shader queues shader `s` over the rectangle of `dst`, reading
// `inputs` (as many as it was made for) and given `uniforms` (at most
// SHADER_UNIFORMS bytes). False for no such shader or canvas, the wrong
// number of inputs, a destination among them, a compute shader's
// destination whose format cannot be written by one, or a rectangle
// outside it.
canvas_shader :: proc(r: ^Renderer, s: Shader, dst: Page, x, y, w, h: u32, inputs: []Page, uniforms: []u8) -> bool {
	st := shader_state(r, s)
	ps := canvas_page(r, dst)
	if st == nil || ps == nil || len(inputs) != st.inputs || len(uniforms) > SHADER_UNIFORMS || !canvas_inside(ps, x, y, w, h) do return false
	if st.stage == .Compute && ps.canvas_format not_in r.canvas_storage do return false
	op := Canvas_Op{kind = .Shader, page = dst, x = x, y = y, w = w, h = h, shader = s, count = len(inputs)}
	for p, i in inputs {
		if canvas_page(r, p) == nil || p == dst do return false
		op.inputs[i] = p
	}
	copy(op.uniforms[:], uniforms)
	append(&r.canvas_ops, op)
	return true
}

// shader_record records one shader op (canvas_flush).
@(private)
shader_record :: proc(r: ^Renderer, cb: ^MTL.CommandBuffer, op: ^Canvas_Op, ps: ^Page_State) -> bool {
	st := shader_state(r, op.shader)
	if st == nil do return false

	// the backdrop, where the shader asked for one: what is under the
	// rectangle now, copied so the shader can read it while writing over it
	backdrop: ^Page_State
	if st.backdrop {
		backdrop = canvas_scratch(r, ps.canvas_format, {op.w, op.h})
		if backdrop == nil do return false
		canvas_blit_texture(cb, ps, op.x, op.y, op.w, op.h, backdrop, 0, 0)
	}

	push := Shader_Push{area = {i32(op.x), i32(op.y), i32(op.w), i32(op.h)}, uniforms = op.uniforms}

	if st.stage == .Compute {
		enc := cb->computeCommandEncoder()
		if enc == nil do return false
		defer enc->endEncoding()
		enc->setComputePipelineState(st.compute)
		enc->setTexture(ps.tex, 0) // the destination, written
		for i in 0 ..< op.count {
			in_ps := canvas_page(r, op.inputs[i])
			if in_ps == nil do return false
			enc->setTexture(in_ps.tex, NS.UInteger(i + 1))
		}
		enc->setBytes(([^]byte)(&push)[:size_of(Shader_Push)], 0)
		// Exactly the rectangle: Metal handles the partial threadgroup at
		// its edges, so there is no overspill for the shader to ignore.
		enc->dispatchThreads(
			MTL.Size{NS.UInteger(op.w), NS.UInteger(op.h), 1},
			MTL.Size{NS.UInteger(st.local.x), NS.UInteger(st.local.y), 1})
		return true
	}

	pipe := st.pipelines[ps.canvas_format]
	if pipe == nil {
		desc := MTL.RenderPipelineDescriptor.alloc()->init()
		defer desc->release()
		if !canvas_library_ensure(r) do return false
		vs := r.canvas_lib->newFunctionWithName(NS.AT("canvas_fs"))
		if vs == nil do return false
		defer vs->release()
		desc->setVertexFunction(vs)
		desc->setFragmentFunction(st.fn)
		att := desc->colorAttachments()->object(0)
		att->setPixelFormat(canvas_metal_format(ps.canvas_format))
		att->setBlendingEnabled(false) // the shader writes the final texel
		made, perr := r.dev->newRenderPipelineStateWithDescriptor(desc)
		if made == nil {
			r.last_error = perr != nil ? string(perr->localizedDescription()->odinString()) : "shader: render pipeline"
			return false
		}
		st.pipelines[ps.canvas_format] = made
		pipe = made
	}
	enc := canvas_encoder(cb, ps, op.x, op.y, op.w, op.h)
	if enc == nil do return false
	defer enc->endEncoding()
	enc->setRenderPipelineState(pipe)
	n := 0
	for i in 0 ..< op.count {
		in_ps := canvas_page(r, op.inputs[i])
		if in_ps == nil do return false
		enc->setFragmentTexture(in_ps.tex, NS.UInteger(n))
		n += 1
	}
	if backdrop != nil {
		enc->setFragmentTexture(backdrop.tex, NS.UInteger(n))
		n += 1
	}
	// A shader may sample rather than read, and the canvases it was given
	// are filtered as they are drawn.
	enc->setFragmentSamplerState(r.sampler, 0)
	enc->setFragmentBytes(([^]byte)(&push)[:size_of(Shader_Push)], 0)
	enc->drawPrimitives(.Triangle, 0, 3)
	return true
}
