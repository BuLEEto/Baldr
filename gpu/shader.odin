#+build !darwin
// shader.odin — an app's own shaders on canvases.
//
// An effect Baldr has no operation for is the app's own shader: SPIR-V it
// built (glslc from GLSL), run on canvases in the same queue as Baldr's
// operations, in the app's order, with textures in and out and uniforms,
// fragment and compute. The contract a shader is written to:
//
// Fragment (shader_create(.Fragment)): drawn over the destination
// rectangle, one invocation a texel (gl_FragCoord.xy is the destination
// texel's centre), writing `layout(location = 0) out vec4` as the texel's
// stored values (straight alpha; no blending). Input i is
// `layout(set = i, binding = 0) uniform sampler2D` (texelFetch it, or
// sample it: canvases are filtered as they are drawn); with `backdrop` one
// more set, after the inputs, holds a copy of the destination rectangle as
// it was (sampled at texel - rectangle origin), for a shader that blends.
//
// Compute (shader_create(.Compute)): dispatched over the destination
// rectangle in its local size's groups, writing the destination as
// `layout(set = 0, binding = 0, rgba8 | rgba16 | rgba32f) uniform image2D`
// (the canvas's format) at any texel (the rectangle is where it should);
// input i is `layout(set = i + 1, binding = 0) uniform sampler2D`. A
// canvas can be a compute shader's destination when its format allows it
// (Limits.storage).
//
// Both: `layout(push_constant) uniform` of up to 128 bytes, the first 16
// Baldr's — ivec4 area: the destination rectangle's x, y, w, h — then the
// app's uniforms (up to 112 bytes, as canvas_shader was given them).
//
// SPIR-V runs on the Vulkan backend; the Metal backend compiles the MSL an
// app gives beside it in Shader_Code (metal_shader.odin).
package gpu

import "core:mem"
import vk "vendor:vulkan"

@(private)
Shader_State :: struct {
	used:      bool,
	stage:     Shader_Stage,
	module:    vk.ShaderModule,
	entry:     cstring, // owned
	inputs:    int,
	backdrop:  bool,
	local:     [2]u32, // a compute shader's local size
	layout:    vk.PipelineLayout,
	pipelines: [Canvas_Format]vk.Pipeline, // a fragment shader's, per destination format (built as drawn into)
	compute:   vk.Pipeline,
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
// SPIR-V is not a module of that stage (its first entry point decides), a
// compute shader has no local size, or Vulkan refuses it.
shader_create :: proc(r: ^Renderer, stage: Shader_Stage, code: Shader_Code, inputs: int, backdrop := false) -> Shader {
	if r.device == nil || inputs < 0 || inputs > SHADER_INPUTS do return 0
	model, entry, local, ok := spirv_entry(code.spirv)
	if !ok do return 0
	st := Shader_State{used = true, stage = stage, inputs = inputs, backdrop = backdrop && stage == .Fragment, local = local, entry = cstring(raw_data(entry))}
	if (stage == .Fragment && model != 4) || (stage == .Compute && (model != 5 || local.x == 0)) {
		shader_state_destroy(r, &st) // the name read
		return 0
	}
	info := vk.ShaderModuleCreateInfo{sType = .SHADER_MODULE_CREATE_INFO, codeSize = len(code.spirv) * size_of(u32), pCode = raw_data(code.spirv)}
	if res := vk.CreateShaderModule(r.device, &info, nil, &st.module); res != .SUCCESS {
		fail(r, "shader_create: vkCreateShaderModule: %v", res)
		shader_state_destroy(r, &st)
		return 0
	}
	sets: [SHADER_INPUTS + 2]vk.DescriptorSetLayout
	n := 0
	if stage == .Compute {
		if !storage_layout_ensure(r) {
			shader_state_destroy(r, &st)
			return 0
		}
		sets[n] = r.storage_layout
		n += 1
	}
	for _ in 0 ..< inputs + (1 if st.backdrop else 0) {
		sets[n] = r.desc_layout
		n += 1
	}
	stages: vk.ShaderStageFlags = {.COMPUTE} if stage == .Compute else {.FRAGMENT}
	push := vk.PushConstantRange{stageFlags = stages, offset = 0, size = size_of(Shader_Push)}
	pl := vk.PipelineLayoutCreateInfo{sType = .PIPELINE_LAYOUT_CREATE_INFO, setLayoutCount = u32(n), pSetLayouts = &sets[0], pushConstantRangeCount = 1, pPushConstantRanges = &push}
	if res := vk.CreatePipelineLayout(r.device, &pl, nil, &st.layout); res != .SUCCESS {
		fail(r, "shader_create: vkCreatePipelineLayout: %v", res)
		shader_state_destroy(r, &st)
		return 0
	}
	if stage == .Compute {
		ci := vk.ComputePipelineCreateInfo{
			sType  = .COMPUTE_PIPELINE_CREATE_INFO,
			stage  = {sType = .PIPELINE_SHADER_STAGE_CREATE_INFO, stage = {.COMPUTE}, module = st.module, pName = st.entry},
			layout = st.layout,
		}
		if res := vk.CreateComputePipelines(r.device, 0, 1, &ci, nil, &st.compute); res != .SUCCESS {
			fail(r, "shader_create: vkCreateComputePipelines: %v", res)
			shader_state_destroy(r, &st)
			return 0
		}
	}
	for &s, i in r.shaders do if !s.used {
		s = st
		return Shader(i + 1)
	}
	append(&r.shaders, st)
	return Shader(len(r.shaders))
}

// shader_destroy frees a shader once the work queued before it is done (it
// waits for the device).
shader_destroy :: proc(r: ^Renderer, s: Shader) {
	st := shader_state(r, s)
	if st == nil do return
	vk.DeviceWaitIdle(r.device)
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
	for p in st.pipelines do if p != 0 do vk.DestroyPipeline(r.device, p, nil)
	if st.compute != 0 do vk.DestroyPipeline(r.device, st.compute, nil)
	if st.layout != 0 do vk.DestroyPipelineLayout(r.device, st.layout, nil)
	if st.module != 0 do vk.DestroyShaderModule(r.device, st.module, nil)
	if st.entry != nil do free(rawptr(st.entry))
	st^ = {}
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
	if st.stage == .Compute && !ps.storage do return false
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
shader_record :: proc(r: ^Renderer, cb: vk.CommandBuffer, op: ^Canvas_Op, ps: ^Page_State, used: ^map[Page]bool, to: proc(cb: vk.CommandBuffer, ps: ^Page_State, layout: vk.ImageLayout)) -> bool {
	st := shader_state(r, op.shader)
	if st == nil do return false
	sets: [SHADER_INPUTS + 2]vk.DescriptorSet
	n := 0
	if st.stage == .Compute {
		set, ok := storage_set(r, ps)
		if !ok do return false
		sets[n] = set
		n += 1
	}
	backdrop: ^Page_State
	if st.backdrop {
		backdrop = canvas_scratch(r, ps.canvas_format, {op.w, op.h})
		if backdrop == nil do return false
		used[r.canvas_scratch[0][ps.canvas_format]] = true
		to(cb, ps, .TRANSFER_SRC_OPTIMAL)
		to(cb, backdrop, .TRANSFER_DST_OPTIMAL)
		region := vk.ImageCopy{
			srcSubresource = {aspectMask = {.COLOR}, layerCount = 1}, srcOffset = {i32(op.x), i32(op.y), 0},
			dstSubresource = {aspectMask = {.COLOR}, layerCount = 1}, extent = {op.w, op.h, 1},
		}
		vk.CmdCopyImage(cb, ps.image, .TRANSFER_SRC_OPTIMAL, backdrop.image, .TRANSFER_DST_OPTIMAL, 1, &region)
		to(cb, backdrop, .SHADER_READ_ONLY_OPTIMAL)
	}
	for i in 0 ..< op.count {
		in_ps := canvas_page(r, op.inputs[i])
		if in_ps == nil do return false
		used[op.inputs[i]] = true
		to(cb, in_ps, .SHADER_READ_ONLY_OPTIMAL)
		sets[n] = in_ps.set
		n += 1
	}
	if backdrop != nil {
		sets[n] = backdrop.set
		n += 1
	}
	push := Shader_Push{area = {i32(op.x), i32(op.y), i32(op.w), i32(op.h)}, uniforms = op.uniforms}
	if st.stage == .Compute {
		to(cb, ps, .GENERAL)
		vk.CmdBindPipeline(cb, .COMPUTE, st.compute)
		if n > 0 do vk.CmdBindDescriptorSets(cb, .COMPUTE, st.layout, 0, u32(n), &sets[0], 0, nil)
		vk.CmdPushConstants(cb, st.layout, {.COMPUTE}, 0, size_of(Shader_Push), &push)
		vk.CmdDispatch(cb, (op.w + st.local.x - 1) / st.local.x, (op.h + max(st.local.y, 1) - 1) / max(st.local.y, 1), 1)
		return true
	}
	pipe := st.pipelines[ps.canvas_format]
	if pipe == 0 {
		ok: bool
		pipe, ok = fullscreen_pipeline_from(r, st.module, st.entry, st.layout, canvas_vk_format(ps.canvas_format))
		if !ok do return false
		st.pipelines[ps.canvas_format] = pipe
	}
	to(cb, ps, .COLOR_ATTACHMENT_OPTIMAL)
	area := vk.Rect2D{offset = {i32(op.x), i32(op.y)}, extent = {op.w, op.h}}
	attach := vk.RenderingAttachmentInfo{sType = .RENDERING_ATTACHMENT_INFO, imageView = ps.target_view, imageLayout = .COLOR_ATTACHMENT_OPTIMAL, loadOp = .LOAD, storeOp = .STORE}
	ri := vk.RenderingInfo{sType = .RENDERING_INFO, renderArea = area, layerCount = 1, colorAttachmentCount = 1, pColorAttachments = &attach}
	if r.khr_dynamic_rendering { vk.CmdBeginRenderingKHR(cb, &ri) } else { vk.CmdBeginRendering(cb, &ri) }
	vk.CmdBindPipeline(cb, .GRAPHICS, pipe)
	vp := vk.Viewport{width = f32(ps.size.x), height = f32(ps.size.y), maxDepth = 1}
	vk.CmdSetViewport(cb, 0, 1, &vp)
	vk.CmdSetScissor(cb, 0, 1, &area)
	if n > 0 do vk.CmdBindDescriptorSets(cb, .GRAPHICS, st.layout, 0, u32(n), &sets[0], 0, nil)
	vk.CmdPushConstants(cb, st.layout, {.FRAGMENT}, 0, size_of(Shader_Push), &push)
	vk.CmdDraw(cb, 3, 1, 0, 0)
	if r.khr_dynamic_rendering { vk.CmdEndRenderingKHR(cb) } else { vk.CmdEndRendering(cb) }
	return true
}

// storage_layout_ensure makes the layout a compute shader writes its
// destination through (a storage image), and the pool its sets come from.
@(private)
storage_layout_ensure :: proc(r: ^Renderer) -> bool {
	if r.storage_layout != 0 do return true
	binding := vk.DescriptorSetLayoutBinding{binding = 0, descriptorType = .STORAGE_IMAGE, descriptorCount = 1, stageFlags = {.COMPUTE}}
	info := vk.DescriptorSetLayoutCreateInfo{sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO, bindingCount = 1, pBindings = &binding}
	if res := vk.CreateDescriptorSetLayout(r.device, &info, nil, &r.storage_layout); res != .SUCCESS {
		fail(r, "shader: storage vkCreateDescriptorSetLayout: %v", res)
		return false
	}
	return true
}

// storage_set is a canvas's storage-image descriptor, made the first time
// a compute shader writes it (freed with the canvas).
@(private)
storage_set :: proc(r: ^Renderer, ps: ^Page_State) -> (vk.DescriptorSet, bool) {
	if ps.storage_set != 0 do return ps.storage_set, true
	if !storage_layout_ensure(r) do return 0, false
	try :: proc(r: ^Renderer, pool: vk.DescriptorPool) -> (set: vk.DescriptorSet, ok: bool) {
		layout := r.storage_layout
		info := vk.DescriptorSetAllocateInfo{sType = .DESCRIPTOR_SET_ALLOCATE_INFO, descriptorPool = pool, descriptorSetCount = 1, pSetLayouts = &layout}
		ok = vk.AllocateDescriptorSets(r.device, &info, &set) == .SUCCESS // before `set` is read: it is what this fills
		return set, ok
	}
	set: vk.DescriptorSet
	ok := false
	if n := len(r.storage_pools); n > 0 do set, ok = try(r, r.storage_pools[n - 1])
	if !ok {
		size := vk.DescriptorPoolSize{type = .STORAGE_IMAGE, descriptorCount = DESC_POOL_SETS}
		pinfo := vk.DescriptorPoolCreateInfo{sType = .DESCRIPTOR_POOL_CREATE_INFO, flags = {.FREE_DESCRIPTOR_SET}, maxSets = DESC_POOL_SETS, poolSizeCount = 1, pPoolSizes = &size}
		pool: vk.DescriptorPool
		if vk.CreateDescriptorPool(r.device, &pinfo, nil, &pool) != .SUCCESS do return 0, false
		append(&r.storage_pools, pool)
		set, ok = try(r, pool)
		if !ok do return 0, false
	}
	img := vk.DescriptorImageInfo{imageView = ps.target_view, imageLayout = .GENERAL}
	write := vk.WriteDescriptorSet{sType = .WRITE_DESCRIPTOR_SET, dstSet = set, dstBinding = 0, descriptorCount = 1, descriptorType = .STORAGE_IMAGE, pImageInfo = &img}
	vk.UpdateDescriptorSets(r.device, 1, &write, 0, nil)
	ps.storage_set, ps.storage_pool = set, r.storage_pools[len(r.storage_pools) - 1]
	return set, true
}

// spirv_entry reads a module's first entry point: its execution model
// (4 Fragment, 5 GLCompute), its name (owned, NUL-ended) and a compute
// shader's local size. False when it is not SPIR-V.
@(private)
spirv_entry :: proc(code: []u32) -> (model: u32, name: []u8, local: [2]u32, ok: bool) {
	if len(code) < 5 || code[0] != 0x07230203 do return
	entry_id: u32
	found := false
	for i := 5; i < len(code); {
		words := int(code[i] >> 16)
		op := code[i] & 0xFFFF
		if words == 0 || i + words > len(code) do return
		switch op {
		case 15: // OpEntryPoint: model, id, name…
			if !found && words >= 4 {
				model, entry_id = code[i + 1], code[i + 2]
				bytes := mem.slice_to_bytes(code[i + 3:i + words])
				n := 0
				for n < len(bytes) && bytes[n] != 0 do n += 1
				name = make([]u8, n + 1)
				copy(name, bytes[:n])
				found = true
			}
		case 16: // OpExecutionMode: id, mode, operands…
			if found && words >= 6 && code[i + 1] == entry_id && code[i + 2] == 17 do local = {code[i + 3], code[i + 4]} // LocalSize
		}
		i += words
	}
	return model, name, local, found
}

// fullscreen_pipeline_from is fullscreen_pipeline_create with an app's
// fragment module and entry point.
@(private)
fullscreen_pipeline_from :: proc(r: ^Renderer, frag: vk.ShaderModule, entry: cstring, layout: vk.PipelineLayout, format: vk.Format) -> (vk.Pipeline, bool) {
	return fullscreen_pipeline_module(r, frag, entry, layout, format)
}
