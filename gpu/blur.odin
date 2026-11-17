#+build !darwin
package gpu

// Frosted glass: the Backdrop command. Everything drawn so far on the
// target's image (its swapchain image, or a transparent target's scene) is
// blitted (downsampled ×4) into a small colour image, Kawase-blurred
// ping-pong a few passes, and bound as BLUR_PAGE so the backdrop quad can
// sample it. The dynamic rendering scope is closed for the blit and passes
// and reopened with loadOp LOAD. Cost is a handful of quarter-resolution
// passes per Backdrop; apps without glass never touch it.

import vk "vendor:vulkan"

// BLUR_PAGE is the pseudo page a Backdrop quad samples: the current blurred scene.

@(private) BLUR_DIVISOR :: u32(4)
@(private) BLUR_FORMAT  :: vk.Format.R8G8B8A8_SRGB

// Sampled_Image is a colour image the renderer draws into and samples: a
// blur target, or a transparent target's scene (present.odin).
@(private)
Sampled_Image :: struct {
	image:  vk.Image,
	memory: vk.DeviceMemory,
	view:   vk.ImageView,
	set:    vk.DescriptorSet,
	pool:   vk.DescriptorPool,
	layout: vk.ImageLayout,
	size:   vk.Extent2D,
}

@(private)
Blur_State :: struct {
	extent:  vk.Extent2D, // target extent these images were built for
	size:    vk.Extent2D, // image size (extent / BLUR_DIVISOR)
	targets: [2]Sampled_Image,
	ready:   bool,
}

@(private)
Blur_Push :: struct {
	texel:  [2]f32,
	offset: f32,
	_pad:   f32,
}

// blur_pass records: end rendering → blit the target's image into blur[0] →
// N Kawase passes → bind the result as BLUR_PAGE → restore the target's
// image and reopen rendering with LOAD. Returns false (with rendering
// reopened untouched) when the target cannot be read or setup failed; the
// backdrop quad then falls back to the white page.
@(private)
blur_pass :: proc(r: ^Renderer, ts: ^Target_State, cb: vk.CommandBuffer, img: u32, radius: f32) -> bool {
	if !(ts.transparent || ts.can_blit) || !blur_ensure(r, ts) { // a scene is always readable
		return false
	}
	bs := &ts.blur
	src_image := render_image(ts, img)
	end_rendering(r, cb)

	// the target's image → transfer source (drawn into, and read too when rendering was reopened with LOAD)
	image_barrier(cb, src_image,
		.COLOR_ATTACHMENT_OPTIMAL, .TRANSFER_SRC_OPTIMAL,
		{.COLOR_ATTACHMENT_OUTPUT}, {.TRANSFER}, {.COLOR_ATTACHMENT_READ, .COLOR_ATTACHMENT_WRITE}, {.TRANSFER_READ})
	// blur[0] → transfer destination
	sampled_image_barrier(cb, &bs.targets[0], .TRANSFER_DST_OPTIMAL)
	blit := vk.ImageBlit{
		srcSubresource = {aspectMask = {.COLOR}, layerCount = 1},
		srcOffsets     = {{0, 0, 0}, {i32(ts.extent.width), i32(ts.extent.height), 1}},
		dstSubresource = {aspectMask = {.COLOR}, layerCount = 1},
		dstOffsets     = {{0, 0, 0}, {i32(bs.size.width), i32(bs.size.height), 1}},
	}
	vk.CmdBlitImage(cb, src_image, .TRANSFER_SRC_OPTIMAL, bs.targets[0].image, .TRANSFER_DST_OPTIMAL, 1, &blit, .LINEAR)

	// Kawase ping-pong. Offsets grow per pass; scaled so `radius` px at full
	// resolution lands near a Gaussian of similar sigma.
	passes := clamp(int(radius / 8) + 1, 2, 6)
	scale := radius / (f32(passes) * f32(BLUR_DIVISOR) * 1.5)
	cur := 0
	for i in 0 ..< passes {
		src := &bs.targets[cur]
		dst := &bs.targets[1 - cur]
		sampled_image_barrier(cb, src, .SHADER_READ_ONLY_OPTIMAL)
		sampled_image_barrier(cb, dst, .COLOR_ATTACHMENT_OPTIMAL)
		attach := vk.RenderingAttachmentInfo{
			sType       = .RENDERING_ATTACHMENT_INFO,
			imageView   = dst.view,
			imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
			loadOp      = .DONT_CARE,
			storeOp     = .STORE,
		}
		ri := vk.RenderingInfo{
			sType                = .RENDERING_INFO,
			renderArea           = {extent = bs.size},
			layerCount           = 1,
			colorAttachmentCount = 1,
			pColorAttachments    = &attach,
		}
		begin_rendering(r, cb, &ri)
		vp := vk.Viewport{width = f32(bs.size.width), height = f32(bs.size.height), minDepth = 0, maxDepth = 1}
		sc := vk.Rect2D{extent = bs.size}
		vk.CmdSetViewport(cb, 0, 1, &vp)
		vk.CmdSetScissor(cb, 0, 1, &sc)
		vk.CmdBindPipeline(cb, .GRAPHICS, r.blur_pipeline)
		set := src.set
		vk.CmdBindDescriptorSets(cb, .GRAPHICS, r.blur_layout, 0, 1, &set, 0, nil)
		pc := Blur_Push{texel = {1 / f32(bs.size.width), 1 / f32(bs.size.height)}, offset = f32(i) * scale}
		vk.CmdPushConstants(cb, r.blur_layout, {.FRAGMENT}, 0, size_of(pc), &pc)
		vk.CmdDraw(cb, 3, 1, 0, 0)
		end_rendering(r, cb)
		cur = 1 - cur
	}
	result := &bs.targets[cur]
	sampled_image_barrier(cb, result, .SHADER_READ_ONLY_OPTIMAL)
	r.cur_blur_set = result.set

	// the target's image back to colour attachment; reopen rendering, keeping contents. LOAD reads what is
	// there, so the barrier declares the read: declared write-only, it is a read-after-write hazard the
	// validation layers flag and a driver is free to act on.
	image_barrier(cb, src_image,
		.TRANSFER_SRC_OPTIMAL, .COLOR_ATTACHMENT_OPTIMAL,
		{.TRANSFER}, {.COLOR_ATTACHMENT_OUTPUT}, {.TRANSFER_READ}, {.COLOR_ATTACHMENT_READ, .COLOR_ATTACHMENT_WRITE})
	attach := vk.RenderingAttachmentInfo{
		sType       = .RENDERING_ATTACHMENT_INFO,
		imageView   = render_view(ts, img),
		imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
		loadOp      = .LOAD,
		storeOp     = .STORE,
	}
	ri := vk.RenderingInfo{
		sType                = .RENDERING_INFO,
		renderArea           = {extent = ts.extent},
		layerCount           = 1,
		colorAttachmentCount = 1,
		pColorAttachments    = &attach,
	}
	begin_rendering(r, cb, &ri)
	return true
}

@(private)
begin_rendering :: proc(r: ^Renderer, cb: vk.CommandBuffer, ri: ^vk.RenderingInfo) {
	if r.khr_dynamic_rendering { vk.CmdBeginRenderingKHR(cb, ri) } else { vk.CmdBeginRendering(cb, ri) }
}

@(private)
end_rendering :: proc(r: ^Renderer, cb: vk.CommandBuffer) {
	if r.khr_dynamic_rendering { vk.CmdEndRenderingKHR(cb) } else { vk.CmdEndRendering(cb) }
}

// blur_ensure builds (or rebuilds after a resize) the two blur images and the
// blur pipeline. Called inside command recording, so it only creates objects.
@(private)
blur_ensure :: proc(r: ^Renderer, ts: ^Target_State) -> bool {
	bs := &ts.blur
	if bs.ready && bs.extent == ts.extent { return true }
	if r.blur_pipeline == 0 && !blur_pipeline_create(r) { return false }
	// Rebuild: the old images may be in use by the frame in flight, so wait.
	if bs.ready { vk.DeviceWaitIdle(r.device); blur_destroy(r, bs) }
	bs.extent = ts.extent
	bs.size = {max(ts.extent.width / BLUR_DIVISOR, 1), max(ts.extent.height / BLUR_DIVISOR, 1)}
	for &t in bs.targets {
		if !sampled_image_create(r, &t, bs.size, BLUR_FORMAT, {.COLOR_ATTACHMENT, .SAMPLED, .TRANSFER_DST}) { blur_destroy(r, bs); return false }
	}
	bs.ready = true
	return true
}

// sampled_image_create makes a device-local colour image of `size`, its view
// and a descriptor set sampling it.
@(private)
sampled_image_create :: proc(r: ^Renderer, t: ^Sampled_Image, size: vk.Extent2D, format: vk.Format, usage: vk.ImageUsageFlags) -> bool {
	info := vk.ImageCreateInfo{
		sType         = .IMAGE_CREATE_INFO,
		imageType     = .D2,
		format        = format,
		extent        = {size.width, size.height, 1},
		mipLevels     = 1,
		arrayLayers   = 1,
		samples       = {._1},
		tiling        = .OPTIMAL,
		usage         = usage,
		sharingMode   = .EXCLUSIVE,
		initialLayout = .UNDEFINED,
	}
	if res := vk.CreateImage(r.device, &info, nil, &t.image); res != .SUCCESS {
		return fail(r, "vkCreateImage(%dx%d): %v", size.width, size.height, res)
	}
	req: vk.MemoryRequirements
	vk.GetImageMemoryRequirements(r.device, t.image, &req)
	type_index, found := find_memory_type(r, req.memoryTypeBits, {.DEVICE_LOCAL})
	if !found { type_index, found = find_memory_type(r, req.memoryTypeBits, {}) }
	if !found { return fail(r, "sampled image: no memory type") }
	alloc := vk.MemoryAllocateInfo{sType = .MEMORY_ALLOCATE_INFO, allocationSize = req.size, memoryTypeIndex = type_index}
	if res := vk.AllocateMemory(r.device, &alloc, nil, &t.memory); res != .SUCCESS {
		return fail(r, "vkAllocateMemory(sampled image): %v", res)
	}
	if res := vk.BindImageMemory(r.device, t.image, t.memory, 0); res != .SUCCESS {
		return fail(r, "vkBindImageMemory(sampled image): %v", res)
	}
	vi := vk.ImageViewCreateInfo{
		sType            = .IMAGE_VIEW_CREATE_INFO,
		image            = t.image,
		viewType         = .D2,
		format           = format,
		subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
	}
	if res := vk.CreateImageView(r.device, &vi, nil, &t.view); res != .SUCCESS {
		return fail(r, "vkCreateImageView(sampled image): %v", res)
	}
	set, pool, ok := desc_set_alloc(r)
	if !ok { return false }
	t.set, t.pool = set, pool
	img_info := vk.DescriptorImageInfo{sampler = r.sampler, imageView = t.view, imageLayout = .SHADER_READ_ONLY_OPTIMAL}
	write := vk.WriteDescriptorSet{
		sType           = .WRITE_DESCRIPTOR_SET,
		dstSet          = t.set,
		dstBinding      = 0,
		descriptorCount = 1,
		descriptorType  = .COMBINED_IMAGE_SAMPLER,
		pImageInfo      = &img_info,
	}
	vk.UpdateDescriptorSets(r.device, 1, &write, 0, nil)
	t.layout = .UNDEFINED
	t.size = size
	return true
}

// sampled_image_destroy frees an image, partly made or whole. Caller
// guarantees the device is idle.
@(private)
sampled_image_destroy :: proc(r: ^Renderer, t: ^Sampled_Image) {
	if t.set != 0 && t.pool != 0 { vk.FreeDescriptorSets(r.device, t.pool, 1, &t.set) }
	if t.view != 0 { vk.DestroyImageView(r.device, t.view, nil) }
	if t.image != 0 { vk.DestroyImage(r.device, t.image, nil) }
	if t.memory != 0 { vk.FreeMemory(r.device, t.memory, nil) }
	t^ = {}
}

// blur_destroy frees the blur images. Caller guarantees the device is idle
// (swapchain_destroy waits; blur_ensure waits before rebuilding).
@(private)
blur_destroy :: proc(r: ^Renderer, bs: ^Blur_State) {
	for &t in bs.targets { sampled_image_destroy(r, &t) }
	bs^ = {}
}

@(private)
sampled_image_barrier :: proc(cb: vk.CommandBuffer, t: ^Sampled_Image, new: vk.ImageLayout) {
	if t.layout == new { return }
	src_stage, dst_stage: vk.PipelineStageFlags
	src_access, dst_access: vk.AccessFlags
	#partial switch t.layout {
	case .UNDEFINED:                src_stage = {.TOP_OF_PIPE};             src_access = {}
	case .TRANSFER_DST_OPTIMAL:     src_stage = {.TRANSFER};                src_access = {.TRANSFER_WRITE}
	case .COLOR_ATTACHMENT_OPTIMAL: src_stage = {.COLOR_ATTACHMENT_OUTPUT}; src_access = {.COLOR_ATTACHMENT_WRITE}
	case .SHADER_READ_ONLY_OPTIMAL: src_stage = {.FRAGMENT_SHADER};         src_access = {.SHADER_READ}
	case:                           src_stage = {.ALL_COMMANDS};            src_access = {.MEMORY_WRITE}
	}
	#partial switch new {
	case .TRANSFER_DST_OPTIMAL:     dst_stage = {.TRANSFER};                dst_access = {.TRANSFER_WRITE}
	case .COLOR_ATTACHMENT_OPTIMAL: dst_stage = {.COLOR_ATTACHMENT_OUTPUT}; dst_access = {.COLOR_ATTACHMENT_WRITE}
	case .SHADER_READ_ONLY_OPTIMAL: dst_stage = {.FRAGMENT_SHADER};         dst_access = {.SHADER_READ}
	case:                           dst_stage = {.ALL_COMMANDS};            dst_access = {.MEMORY_READ, .MEMORY_WRITE}
	}
	image_barrier(cb, t.image, t.layout, new, src_stage, dst_stage, src_access, dst_access)
	t.layout = new
}

@(private)
image_barrier :: proc(cb: vk.CommandBuffer, image: vk.Image, old, new: vk.ImageLayout,
	src_stage, dst_stage: vk.PipelineStageFlags, src_access, dst_access: vk.AccessFlags) {
	b := vk.ImageMemoryBarrier{
		sType               = .IMAGE_MEMORY_BARRIER,
		srcAccessMask       = src_access,
		dstAccessMask       = dst_access,
		oldLayout           = old,
		newLayout           = new,
		srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		image               = image,
		subresourceRange    = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
	}
	vk.CmdPipelineBarrier(cb, src_stage, dst_stage, {}, 0, nil, 0, nil, 1, &b)
}

// blur_pipeline_create builds the Kawase pass pipeline into BLUR_FORMAT
// targets, with fragment push constants (texel size + offset).
@(private)
blur_pipeline_create :: proc(r: ^Renderer) -> bool {
	if r.blur_layout == 0 {
		layout, ok := push_layout_create(r, size_of(Blur_Push))
		if !ok { return false }
		r.blur_layout = layout
	}
	p, ok := fullscreen_pipeline_create(r, BLUR_FRAG_SPV, r.blur_layout, BLUR_FORMAT)
	r.blur_pipeline = p
	return ok
}

// push_layout_create makes a pipeline layout of the texture set and a
// fragment push constant of `size` bytes.
@(private)
push_layout_create :: proc(r: ^Renderer, size: u32) -> (layout: vk.PipelineLayout, ok: bool) {
	push := vk.PushConstantRange{stageFlags = {.FRAGMENT}, offset = 0, size = size}
	set_layout := r.desc_layout
	pl := vk.PipelineLayoutCreateInfo{
		sType                  = .PIPELINE_LAYOUT_CREATE_INFO,
		setLayoutCount         = 1,
		pSetLayouts            = &set_layout,
		pushConstantRangeCount = 1,
		pPushConstantRanges    = &push,
	}
	if res := vk.CreatePipelineLayout(r.device, &pl, nil, &layout); res != .SUCCESS {
		fail(r, "vkCreatePipelineLayout: %v", res)
		return 0, false
	}
	return layout, true
}

// fullscreen_pipeline_create builds a pipeline drawing one triangle over the
// viewport (fullscreen.vert) with fragment shader `frag` into `format`: no
// vertex input, no blending. The Kawase passes and the present pass use it.
@(private)
fullscreen_pipeline_create :: proc(r: ^Renderer, frag_spv: []u32, layout: vk.PipelineLayout, format: vk.Format) -> (pipeline: vk.Pipeline, ok: bool) {
	info := vk.ShaderModuleCreateInfo{sType = .SHADER_MODULE_CREATE_INFO, codeSize = len(frag_spv) * size_of(u32), pCode = raw_data(frag_spv)}
	frag: vk.ShaderModule
	if res := vk.CreateShaderModule(r.device, &info, nil, &frag); res != .SUCCESS {
		fail(r, "vkCreateShaderModule(fullscreen): %v", res)
		return 0, false
	}
	defer vk.DestroyShaderModule(r.device, frag, nil)
	return fullscreen_pipeline_module(r, frag, "main", layout, format)
}

// fullscreen_pipeline_module is fullscreen_pipeline_create from a fragment
// module already made, and its entry point.
@(private)
fullscreen_pipeline_module :: proc(r: ^Renderer, frag: vk.ShaderModule, entry: cstring, layout: vk.PipelineLayout, format: vk.Format) -> (pipeline: vk.Pipeline, ok: bool) {
	make_module :: proc(r: ^Renderer, code: []u32) -> (m: vk.ShaderModule, ok: bool) {
		info := vk.ShaderModuleCreateInfo{sType = .SHADER_MODULE_CREATE_INFO, codeSize = len(code) * size_of(u32), pCode = raw_data(code)}
		res := vk.CreateShaderModule(r.device, &info, nil, &m)
		if res != .SUCCESS { fail(r, "vkCreateShaderModule(fullscreen): %v", res) }
		return m, res == .SUCCESS
	}
	vert, vok := make_module(r, BLUR_VERT_SPV)
	if !vok { return 0, false }
	defer vk.DestroyShaderModule(r.device, vert, nil)
	stages := [2]vk.PipelineShaderStageCreateInfo{
		{sType = .PIPELINE_SHADER_STAGE_CREATE_INFO, stage = {.VERTEX},   module = vert, pName = "main"},
		{sType = .PIPELINE_SHADER_STAGE_CREATE_INFO, stage = {.FRAGMENT}, module = frag, pName = entry},
	}
	vertex_input := vk.PipelineVertexInputStateCreateInfo{sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO}
	assembly := vk.PipelineInputAssemblyStateCreateInfo{sType = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO, topology = .TRIANGLE_LIST}
	viewport := vk.PipelineViewportStateCreateInfo{sType = .PIPELINE_VIEWPORT_STATE_CREATE_INFO, viewportCount = 1, scissorCount = 1}
	raster := vk.PipelineRasterizationStateCreateInfo{sType = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO, polygonMode = .FILL, frontFace = .CLOCKWISE, lineWidth = 1}
	multisample := vk.PipelineMultisampleStateCreateInfo{sType = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO, rasterizationSamples = {._1}}
	blend_attachment := vk.PipelineColorBlendAttachmentState{colorWriteMask = {.R, .G, .B, .A}}
	blend := vk.PipelineColorBlendStateCreateInfo{sType = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO, attachmentCount = 1, pAttachments = &blend_attachment}
	dyn_states := [2]vk.DynamicState{.VIEWPORT, .SCISSOR}
	dyn_state := vk.PipelineDynamicStateCreateInfo{sType = .PIPELINE_DYNAMIC_STATE_CREATE_INFO, dynamicStateCount = len(dyn_states), pDynamicStates = &dyn_states[0]}
	fmt_copy := format
	rendering := vk.PipelineRenderingCreateInfo{sType = .PIPELINE_RENDERING_CREATE_INFO, colorAttachmentCount = 1, pColorAttachmentFormats = &fmt_copy}
	info := vk.GraphicsPipelineCreateInfo{
		sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
		pNext               = &rendering,
		stageCount          = len(stages),
		pStages             = &stages[0],
		pVertexInputState   = &vertex_input,
		pInputAssemblyState = &assembly,
		pViewportState      = &viewport,
		pRasterizationState = &raster,
		pMultisampleState   = &multisample,
		pColorBlendState    = &blend,
		pDynamicState       = &dyn_state,
		layout              = layout,
	}
	if res := vk.CreateGraphicsPipelines(r.device, 0, 1, &info, nil, &pipeline); res != .SUCCESS {
		fail(r, "vkCreateGraphicsPipelines(%v): %v", format, res)
		return 0, false
	}
	return pipeline, true
}
