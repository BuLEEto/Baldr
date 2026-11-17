#+build !darwin
// device.odin — physical-device selection, logical device + queue, and the
// GPU objects shared by every target: command pool, descriptor set layout,
// sampler, pipeline layout, and the one graphics pipeline (cached per
// swapchain colour format). Created lazily by the first target_add because
// device selection needs a surface to test presentation against.
package gpu

import "core:fmt"
import "core:os"
import vk "vendor:vulkan"

VERT_SPV := #load("shaders/ui.vert.spv", []u32)
FRAG_SPV := #load("shaders/ui.frag.spv", []u32)
BLUR_VERT_SPV := #load("shaders/fullscreen.vert.spv", []u32)
BLUR_FRAG_SPV := #load("shaders/kawase.frag.spv", []u32)
PRESENT_FRAG_SPV := #load("shaders/present.frag.spv", []u32)



// Push constant: viewport size in px (vertex stage only).
Push_Constants :: struct {
	viewport: [2]f32,
}

@(private)
find_graphics_present_family :: proc(d: vk.PhysicalDevice, surface: vk.SurfaceKHR) -> (u32, bool) {
	count: u32
	vk.GetPhysicalDeviceQueueFamilyProperties(d, &count, nil)
	props := make([]vk.QueueFamilyProperties, count, context.temp_allocator)
	vk.GetPhysicalDeviceQueueFamilyProperties(d, &count, raw_data(props))
	for p, i in props {
		if .GRAPHICS not_in p.queueFlags { continue }
		present_ok: b32
		vk.GetPhysicalDeviceSurfaceSupportKHR(d, u32(i), surface, &present_ok)
		if present_ok { return u32(i), true }
	}
	return 0, false
}

// pick_physical_device scores every device that can present to `surface`
// and has VK_KHR_swapchain: discrete > integrated > other, 1.3 preferred.
@(private)
pick_physical_device :: proc(r: ^Renderer, surface: vk.SurfaceKHR) -> bool {
	count: u32
	vk.EnumeratePhysicalDevices(r.inst, &count, nil)
	if count == 0 { return fail(r, "no Vulkan devices") }
	devices := make([]vk.PhysicalDevice, count, context.temp_allocator)
	vk.EnumeratePhysicalDevices(r.inst, &count, raw_data(devices))

	best := -1
	for d in devices {
		qf, ok := find_graphics_present_family(d, surface)
		if !ok { continue }
		if !has_device_ext(d, vk.KHR_SWAPCHAIN_EXTENSION_NAME) { continue }
		props: vk.PhysicalDeviceProperties
		vk.GetPhysicalDeviceProperties(d, &props)
		if props.apiVersion < vk.API_VERSION_1_2 { continue }
		if props.apiVersion < vk.API_VERSION_1_3 && !has_device_ext(d, vk.KHR_DYNAMIC_RENDERING_EXTENSION_NAME) { continue }
		score := 1
		if props.deviceType == .DISCRETE_GPU   { score += 1000 }
		if props.deviceType == .INTEGRATED_GPU { score += 100 }
		if props.apiVersion >= vk.API_VERSION_1_3 { score += 10 }
		if score > best {
			best = score
			r.phys = d
			r.qfamily = qf
			r.max_image_dim = props.limits.maxImageDimension2D
			delete(r.device_name)
			r.device_name = fmt.aprintf("%s (Vulkan %d.%d.%d, driver %d.%d.%d)",
				cstring(&props.deviceName[0]),
				props.apiVersion >> 22, (props.apiVersion >> 12) & 0x3ff, props.apiVersion & 0xfff,
				props.driverVersion >> 22, (props.driverVersion >> 12) & 0x3ff, props.driverVersion & 0xfff)
		}
	}
	if best < 0 {
		return fail(r, "no Vulkan 1.2+ device with graphics+present for this surface, VK_KHR_swapchain and dynamic rendering")
	}
	return true
}

// device_create picks the physical device for `surface`, creates the logical
// device with dynamic rendering (core 1.3 or VK_KHR_dynamic_rendering on 1.2),
// VK_KHR_incremental_present when offered, and every shared object.
@(private)
device_create :: proc(r: ^Renderer, surface: vk.SurfaceKHR) -> bool {
	if !pick_physical_device(r, surface) { return false }

	props: vk.PhysicalDeviceProperties
	vk.GetPhysicalDeviceProperties(r.phys, &props)
	use_13 := props.apiVersion >= vk.API_VERSION_1_3 && r.instance_version >= vk.API_VERSION_1_3

	exts := make([dynamic]cstring, context.temp_allocator)
	append(&exts, vk.KHR_SWAPCHAIN_EXTENSION_NAME)
	if has_device_ext(r.phys, vk.KHR_INCREMENTAL_PRESENT_EXTENSION_NAME) {
		if os.get_env("BALDR_NO_INCREMENTAL_PRESENT", context.temp_allocator) != "" {
			// A diagnosis switch: every present damages the whole surface, so a
			// compositor never repaints less than all of it (is a stale region
			// the damage hint's fault, or the compositor's?).
			fmt.eprintln("gpu: incremental present off (BALDR_NO_INCREMENTAL_PRESENT): every present damages the whole surface")
		} else {
			append(&exts, vk.KHR_INCREMENTAL_PRESENT_EXTENSION_NAME)
			r.has_incremental_present = true
		}
	}
	dmabuf_extensions(r, &exts) // importing GPU buffers from other processes, when the device can
	dmabuf_node(r)              // …and which card it is, for a producer that must use the same one
	if has_device_ext(r.phys, vk.KHR_PORTABILITY_SUBSET_EXTENSION_NAME) {
		append(&exts, vk.KHR_PORTABILITY_SUBSET_EXTENSION_NAME) // MoltenVK requires it when present
		r.portability_subset = true
	}

	// Feature query + enable: only dynamicRendering is needed.
	f13 := vk.PhysicalDeviceVulkan13Features{sType = .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES}
	fdr := vk.PhysicalDeviceDynamicRenderingFeatures{sType = .PHYSICAL_DEVICE_DYNAMIC_RENDERING_FEATURES}
	f2  := vk.PhysicalDeviceFeatures2{sType = .PHYSICAL_DEVICE_FEATURES_2}
	if use_13 {
		f2.pNext = &f13
	} else {
		append(&exts, vk.KHR_DYNAMIC_RENDERING_EXTENSION_NAME)
		r.khr_dynamic_rendering = true
		f2.pNext = &fdr
	}
	vk.GetPhysicalDeviceFeatures2(r.phys, &f2)
	if (use_13 && !f13.dynamicRendering) || (!use_13 && !fdr.dynamicRendering) {
		return fail(r, "%s: dynamicRendering feature not supported", r.device_name)
	}
	enable13 := vk.PhysicalDeviceVulkan13Features{sType = .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES, dynamicRendering = true}
	enabledr := vk.PhysicalDeviceDynamicRenderingFeatures{sType = .PHYSICAL_DEVICE_DYNAMIC_RENDERING_FEATURES, dynamicRendering = true}

	prio: f32 = 1
	qinfo := vk.DeviceQueueCreateInfo{
		sType            = .DEVICE_QUEUE_CREATE_INFO,
		queueFamilyIndex = r.qfamily,
		queueCount       = 1,
		pQueuePriorities = &prio,
	}
	info := vk.DeviceCreateInfo{
		sType                   = .DEVICE_CREATE_INFO,
		pNext                   = rawptr(&enable13) if use_13 else rawptr(&enabledr),
		queueCreateInfoCount    = 1,
		pQueueCreateInfos       = &qinfo,
		enabledExtensionCount   = u32(len(exts)),
		ppEnabledExtensionNames = raw_data(exts),
	}
	if res := vk.CreateDevice(r.phys, &info, nil, &r.device); res != .SUCCESS {
		r.device = nil
		return fail(r, "vkCreateDevice: %v", res)
	}
	vk.load_proc_addresses_device(r.device)
	vk.GetDeviceQueue(r.device, r.qfamily, 0, &r.queue)
	vk.GetPhysicalDeviceMemoryProperties(r.phys, &r.mem_props)

	pool := vk.CommandPoolCreateInfo{
		sType            = .COMMAND_POOL_CREATE_INFO,
		flags            = {.RESET_COMMAND_BUFFER},
		queueFamilyIndex = r.qfamily,
	}
	if res := vk.CreateCommandPool(r.device, &pool, nil, &r.cmd_pool); res != .SUCCESS {
		return fail(r, "vkCreateCommandPool: %v", res)
	}

	binding := vk.DescriptorSetLayoutBinding{
		binding         = 0,
		descriptorType  = .COMBINED_IMAGE_SAMPLER,
		descriptorCount = 1,
		stageFlags      = {.FRAGMENT, .COMPUTE}, // an app's compute shader reads canvases through it too (shader.odin)
	}
	layout_info := vk.DescriptorSetLayoutCreateInfo{
		sType        = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		bindingCount = 1,
		pBindings    = &binding,
	}
	if res := vk.CreateDescriptorSetLayout(r.device, &layout_info, nil, &r.desc_layout); res != .SUCCESS {
		return fail(r, "vkCreateDescriptorSetLayout: %v", res)
	}

	sampler := vk.SamplerCreateInfo{
		sType        = .SAMPLER_CREATE_INFO,
		magFilter    = .LINEAR,
		minFilter    = .LINEAR,
		mipmapMode   = .NEAREST,
		addressModeU = .CLAMP_TO_EDGE,
		addressModeV = .CLAMP_TO_EDGE,
		addressModeW = .CLAMP_TO_EDGE,
		maxLod       = 0.25,
		borderColor  = .FLOAT_TRANSPARENT_BLACK,
	}
	if res := vk.CreateSampler(r.device, &sampler, nil, &r.sampler); res != .SUCCESS {
		return fail(r, "vkCreateSampler: %v", res)
	}
	// a picture's own texture: trilinear across its mip levels, so one drawn
	// smaller than it is averages what falls in a pixel instead of skipping
	// texels
	mip := sampler
	mip.mipmapMode = .LINEAR
	mip.maxLod = vk.LOD_CLAMP_NONE
	if res := vk.CreateSampler(r.device, &mip, nil, &r.mip_sampler); res != .SUCCESS {
		return fail(r, "vkCreateSampler (mip): %v", res)
	}
	fp: vk.FormatProperties
	vk.GetPhysicalDeviceFormatProperties(r.phys, .R8G8B8A8_SRGB, &fp)
	mip_needs := vk.FormatFeatureFlags{.BLIT_SRC, .BLIT_DST, .SAMPLED_IMAGE_FILTER_LINEAR}
	r.blit_mips = mip_needs <= fp.optimalTilingFeatures
	nearest := sampler
	nearest.magFilter, nearest.minFilter = .NEAREST, .NEAREST
	if res := vk.CreateSampler(r.device, &nearest, nil, &r.nearest_sampler); res != .SUCCESS {
		return fail(r, "vkCreateSampler (nearest): %v", res)
	}
	canvas_formats_probe(r)

	push := vk.PushConstantRange{stageFlags = {.VERTEX}, offset = 0, size = size_of(Push_Constants)}
	pl := vk.PipelineLayoutCreateInfo{
		sType                  = .PIPELINE_LAYOUT_CREATE_INFO,
		setLayoutCount         = 1,
		pSetLayouts            = &r.desc_layout,
		pushConstantRangeCount = 1,
		pPushConstantRanges    = &push,
	}
	if res := vk.CreatePipelineLayout(r.device, &pl, nil, &r.pipeline_layout); res != .SUCCESS {
		return fail(r, "vkCreatePipelineLayout: %v", res)
	}

	// Page 1: the built-in 1×1 white Alpha8 page (see atlas.odin).
	if white_page_create(r) != WHITE_PAGE {
		return fail(r, "cannot create the default white atlas page")
	}
	return true
}

// pipeline_for_format returns the graphics pipeline for a swapchain colour
// format, creating and caching it on first use.
@(private)
pipeline_for_format :: proc(r: ^Renderer, format: vk.Format) -> (vk.Pipeline, bool) {
	for e in r.pipelines {
		if e.format == format { return e.pipeline, true }
	}
	p, ok := pipeline_create(r, format)
	if !ok { return 0, false }
	append(&r.pipelines, Pipeline_Entry{format, p})
	return p, true
}

@(private)
pipeline_create :: proc(r: ^Renderer, color_format: vk.Format) -> (pipeline: vk.Pipeline, ok: bool) {
	make_module :: proc(r: ^Renderer, code: []u32) -> (m: vk.ShaderModule, ok: bool) {
		info := vk.ShaderModuleCreateInfo{
			sType    = .SHADER_MODULE_CREATE_INFO,
			codeSize = len(code) * size_of(u32),
			pCode    = raw_data(code),
		}
		res := vk.CreateShaderModule(r.device, &info, nil, &m)
		if res != .SUCCESS { fail(r, "vkCreateShaderModule: %v", res) }
		return m, res == .SUCCESS
	}
	vert, vok := make_module(r, VERT_SPV)
	if !vok { return 0, false }
	defer vk.DestroyShaderModule(r.device, vert, nil)
	frag, fok := make_module(r, FRAG_SPV)
	if !fok { return 0, false }
	defer vk.DestroyShaderModule(r.device, frag, nil)

	stages := [2]vk.PipelineShaderStageCreateInfo{
		{sType = .PIPELINE_SHADER_STAGE_CREATE_INFO, stage = {.VERTEX},   module = vert, pName = "main"},
		{sType = .PIPELINE_SHADER_STAGE_CREATE_INFO, stage = {.FRAGMENT}, module = frag, pName = "main"},
	}
	binding := vk.VertexInputBindingDescription{binding = 0, stride = size_of(Vertex), inputRate = .VERTEX}
	attrs := [8]vk.VertexInputAttributeDescription{
		{location = 0, binding = 0, format = .R32G32_SFLOAT,       offset = u32(offset_of(Vertex, pos))},
		{location = 1, binding = 0, format = .R32G32_SFLOAT,       offset = u32(offset_of(Vertex, uv))},
		{location = 2, binding = 0, format = .R32G32B32A32_SFLOAT, offset = u32(offset_of(Vertex, color))},
		{location = 3, binding = 0, format = .R32G32B32A32_SFLOAT, offset = u32(offset_of(Vertex, rect))},
		{location = 4, binding = 0, format = .R32_SFLOAT,          offset = u32(offset_of(Vertex, radius))},
		{location = 5, binding = 0, format = .R32_SFLOAT,          offset = u32(offset_of(Vertex, border_w))},
		{location = 6, binding = 0, format = .R32G32B32A32_SFLOAT, offset = u32(offset_of(Vertex, border))},
		{location = 7, binding = 0, format = .R32_UINT,            offset = u32(offset_of(Vertex, kind))},
	}
	vertex_input := vk.PipelineVertexInputStateCreateInfo{
		sType                           = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
		vertexBindingDescriptionCount   = 1,
		pVertexBindingDescriptions      = &binding,
		vertexAttributeDescriptionCount = len(attrs),
		pVertexAttributeDescriptions    = &attrs[0],
	}
	assembly := vk.PipelineInputAssemblyStateCreateInfo{
		sType    = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
		topology = .TRIANGLE_LIST,
	}
	viewport := vk.PipelineViewportStateCreateInfo{
		sType         = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
		viewportCount = 1,
		scissorCount  = 1, // both dynamic: resize never rebuilds the pipeline
	}
	raster := vk.PipelineRasterizationStateCreateInfo{
		sType       = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
		polygonMode = .FILL,
		cullMode    = {},
		frontFace   = .CLOCKWISE,
		lineWidth   = 1,
	}
	multisample := vk.PipelineMultisampleStateCreateInfo{
		sType                = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
		rasterizationSamples = {._1},
	}
	// Straight-alpha "over". Onto a premultiplied clear this leaves pixels
	// premultiplied in linear light, which a transparent target's present
	// pass converts to the premultiplied sRGB a compositor reads (present.odin).
	blend_attachment := vk.PipelineColorBlendAttachmentState{
		blendEnable         = true,
		srcColorBlendFactor = .SRC_ALPHA,
		dstColorBlendFactor = .ONE_MINUS_SRC_ALPHA,
		colorBlendOp        = .ADD,
		srcAlphaBlendFactor = .ONE,
		dstAlphaBlendFactor = .ONE_MINUS_SRC_ALPHA,
		alphaBlendOp        = .ADD,
		colorWriteMask      = {.R, .G, .B, .A},
	}
	blend := vk.PipelineColorBlendStateCreateInfo{
		sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
		attachmentCount = 1,
		pAttachments    = &blend_attachment,
	}
	dyn_states := [2]vk.DynamicState{.VIEWPORT, .SCISSOR}
	dyn_state := vk.PipelineDynamicStateCreateInfo{
		sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
		dynamicStateCount = len(dyn_states),
		pDynamicStates    = &dyn_states[0],
	}
	fmt_copy := color_format
	rendering := vk.PipelineRenderingCreateInfo{
		sType                   = .PIPELINE_RENDERING_CREATE_INFO,
		colorAttachmentCount    = 1,
		pColorAttachmentFormats = &fmt_copy,
	}
	info := vk.GraphicsPipelineCreateInfo{
		sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
		pNext               = &rendering, // dynamic rendering: no VkRenderPass
		stageCount          = len(stages),
		pStages             = &stages[0],
		pVertexInputState   = &vertex_input,
		pInputAssemblyState = &assembly,
		pViewportState      = &viewport,
		pRasterizationState = &raster,
		pMultisampleState   = &multisample,
		pColorBlendState    = &blend,
		pDynamicState       = &dyn_state,
		layout              = r.pipeline_layout,
	}
	if res := vk.CreateGraphicsPipelines(r.device, 0, 1, &info, nil, &pipeline); res != .SUCCESS {
		fail(r, "vkCreateGraphicsPipelines(%v): %v", color_format, res)
		return 0, false
	}
	return pipeline, true
}
