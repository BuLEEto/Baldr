#+build linux
package main

// vk.odin — Vulkan renderer for the spike. libvulkan.so.1 is dlopen'd, the
// loader's vkGetInstanceProcAddr feeds vendor:vulkan's proc tables, and the
// window surface comes from VK_KHR_wayland_surface using the libwayland
// proxies created in wl.odin.  Vulkan 1.3 dynamic rendering, one graphics
// pipeline, no vertex buffers, FIFO swapchain, binary semaphores + fences.

import "base:runtime"
import "core:dynlib"
import "core:fmt"
import vk "vendor:vulkan"

FRAMES_IN_FLIGHT :: 2

VERT_SPV := #load("shaders/tri.vert.spv", []u32)
FRAG_SPV := #load("shaders/tri.frag.spv", []u32)

Renderer :: struct {
	lib:                   dynlib.Library,
	instance:              vk.Instance,
	instance_version:      u32,
	messenger:             vk.DebugUtilsMessengerEXT,
	validation:            bool,
	validation_errors:     int,
	validation_warnings:   int,
	surface:               vk.SurfaceKHR,
	phys:                  vk.PhysicalDevice,
	device_name:           string,
	qfamily:               u32,
	device:                vk.Device,
	queue:                 vk.Queue,
	khr_dynamic_rendering: bool, // 1.2 device: VK_KHR_dynamic_rendering instead of core 1.3

	format:                vk.SurfaceFormatKHR,
	present_mode:          vk.PresentModeKHR,
	swapchain:             vk.SwapchainKHR,
	extent:                vk.Extent2D,
	images:                []vk.Image,
	views:                 []vk.ImageView,
	cmd_bufs:              []vk.CommandBuffer, // one per swapchain image
	render_finished:       []vk.Semaphore,     // one per swapchain image (present waits on it)
	image_fence:           []vk.Fence,         // slot fence that last used the image, 0 = never

	cmd_pool:              vk.CommandPool,
	image_available:       [FRAMES_IN_FLIGHT]vk.Semaphore,
	in_flight:             [FRAMES_IN_FLIGHT]vk.Fence,
	slot:                  u32,

	pipeline_layout:       vk.PipelineLayout,
	pipeline:              vk.Pipeline,
	frames_presented:      u64,
}

// ------------------------------------------------------------ loader boot

vk_boot :: proc(r: ^Renderer) -> bool {
	lib, ok := dynlib.load_library("libvulkan.so.1")
	if !ok {
		fmt.eprintln("vk: dlopen libvulkan.so.1 failed:", dynlib.last_error())
		return false
	}
	r.lib = lib
	gipa, found := dynlib.symbol_address(lib, "vkGetInstanceProcAddr")
	if !found || gipa == nil {
		fmt.eprintln("vk: vkGetInstanceProcAddr not found")
		return false
	}
	vk.load_proc_addresses_global(gipa)
	if vk.CreateInstance == nil || vk.EnumerateInstanceExtensionProperties == nil {
		fmt.eprintln("vk: global entry points missing")
		return false
	}
	return true
}

@(private="file")
has_layer :: proc(name: string) -> bool {
	count: u32
	vk.EnumerateInstanceLayerProperties(&count, nil)
	props := make([]vk.LayerProperties, count, context.temp_allocator)
	vk.EnumerateInstanceLayerProperties(&count, raw_data(props))
	for &p in props {
		if string(cstring(&p.layerName[0])) == name { return true }
	}
	return false
}

@(private="file")
has_instance_ext :: proc(name: string) -> bool {
	count: u32
	vk.EnumerateInstanceExtensionProperties(nil, &count, nil)
	props := make([]vk.ExtensionProperties, count, context.temp_allocator)
	vk.EnumerateInstanceExtensionProperties(nil, &count, raw_data(props))
	for &p in props {
		if string(cstring(&p.extensionName[0])) == name { return true }
	}
	return false
}

@(private="file")
has_device_ext :: proc(phys: vk.PhysicalDevice, name: string) -> bool {
	count: u32
	vk.EnumerateDeviceExtensionProperties(phys, nil, &count, nil)
	props := make([]vk.ExtensionProperties, count, context.temp_allocator)
	vk.EnumerateDeviceExtensionProperties(phys, nil, &count, raw_data(props))
	for &p in props {
		if string(cstring(&p.extensionName[0])) == name { return true }
	}
	return false
}

@(private="file")
debug_callback :: proc "system" (
	severity: vk.DebugUtilsMessageSeverityFlagsEXT,
	types:    vk.DebugUtilsMessageTypeFlagsEXT,
	data:     ^vk.DebugUtilsMessengerCallbackDataEXT,
	user:     rawptr,
) -> b32 {
	context = runtime.default_context()
	r := (^Renderer)(user)
	if .ERROR in severity {
		r.validation_errors += 1
	} else if .WARNING in severity {
		r.validation_warnings += 1
	}
	fmt.eprintfln("vk validation %v: %s", severity, data.pMessage)
	return false
}

// ---------------------------------------------------------------- instance

vk_create_instance :: proc(r: ^Renderer) -> bool {
	loader_version: u32 = vk.API_VERSION_1_0
	if vk.EnumerateInstanceVersion != nil {
		vk.EnumerateInstanceVersion(&loader_version)
	}
	r.instance_version = vk.API_VERSION_1_3 if loader_version >= vk.API_VERSION_1_3 else vk.API_VERSION_1_2
	if loader_version < vk.API_VERSION_1_2 {
		fmt.eprintfln("vk: loader only supports %d.%d", loader_version >> 22, (loader_version >> 12) & 0x3ff)
		return false
	}

	exts := make([dynamic]cstring, context.temp_allocator)
	append(&exts, vk.KHR_SURFACE_EXTENSION_NAME, vk.KHR_WAYLAND_SURFACE_EXTENSION_NAME)
	if !has_instance_ext(vk.KHR_WAYLAND_SURFACE_EXTENSION_NAME) {
		fmt.eprintln("vk: VK_KHR_wayland_surface not available")
		return false
	}
	layers := make([dynamic]cstring, context.temp_allocator)
	VALIDATION :: "VK_LAYER_KHRONOS_validation"
	if has_layer(VALIDATION) && has_instance_ext(vk.EXT_DEBUG_UTILS_EXTENSION_NAME) {
		append(&layers, VALIDATION)
		append(&exts, vk.EXT_DEBUG_UTILS_EXTENSION_NAME)
		r.validation = true
	}

	app := vk.ApplicationInfo{
		sType              = .APPLICATION_INFO,
		pApplicationName   = "Baldr spike",
		applicationVersion = vk.MAKE_VERSION(0, 0, 1),
		pEngineName        = "baldr",
		engineVersion      = vk.MAKE_VERSION(0, 0, 1),
		apiVersion         = r.instance_version,
	}
	dbg := vk.DebugUtilsMessengerCreateInfoEXT{
		sType           = .DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
		messageSeverity = {.WARNING, .ERROR},
		messageType     = {.GENERAL, .VALIDATION, .PERFORMANCE},
		pfnUserCallback = debug_callback,
		pUserData       = r,
	}
	info := vk.InstanceCreateInfo{
		sType                   = .INSTANCE_CREATE_INFO,
		pNext                   = &dbg if r.validation else nil, // catches CreateInstance-time messages too
		pApplicationInfo        = &app,
		enabledLayerCount       = u32(len(layers)),
		ppEnabledLayerNames     = raw_data(layers),
		enabledExtensionCount   = u32(len(exts)),
		ppEnabledExtensionNames = raw_data(exts),
	}
	if res := vk.CreateInstance(&info, nil, &r.instance); res != .SUCCESS {
		fmt.eprintfln("vk: CreateInstance: %v", res)
		return false
	}
	vk.load_proc_addresses_instance(r.instance)
	if r.validation && vk.CreateDebugUtilsMessengerEXT != nil {
		if res := vk.CreateDebugUtilsMessengerEXT(r.instance, &dbg, nil, &r.messenger); res != .SUCCESS {
			fmt.eprintfln("vk: CreateDebugUtilsMessengerEXT: %v", res)
		}
	}
	return true
}

// ----------------------------------------------------------------- surface

vk_create_wayland_surface :: proc(r: ^Renderer, display: Display, surface: Proxy) -> bool {
	info := vk.WaylandSurfaceCreateInfoKHR{
		sType   = .WAYLAND_SURFACE_CREATE_INFO_KHR,
		display = (^vk.wl_display)(display),
		surface = (^vk.wl_surface)(surface),
	}
	if res := vk.CreateWaylandSurfaceKHR(r.instance, &info, nil, &r.surface); res != .SUCCESS {
		fmt.eprintfln("vk: CreateWaylandSurfaceKHR: %v", res)
		return false
	}
	return true
}

// ------------------------------------------------------------------ device

@(private="file")
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

vk_pick_physical_device :: proc(r: ^Renderer) -> bool {
	count: u32
	vk.EnumeratePhysicalDevices(r.instance, &count, nil)
	if count == 0 {
		fmt.eprintln("vk: no Vulkan devices")
		return false
	}
	devices := make([]vk.PhysicalDevice, count, context.temp_allocator)
	vk.EnumeratePhysicalDevices(r.instance, &count, raw_data(devices))

	best := -1
	for d in devices {
		qf, ok := find_graphics_present_family(d, r.surface)
		if !ok { continue }
		if !has_device_ext(d, vk.KHR_SWAPCHAIN_EXTENSION_NAME) { continue }
		props: vk.PhysicalDeviceProperties
		vk.GetPhysicalDeviceProperties(d, &props)
		if props.apiVersion < vk.API_VERSION_1_2 { continue }
		score := 1
		if props.deviceType == .DISCRETE_GPU   { score += 1000 }
		if props.deviceType == .INTEGRATED_GPU { score += 100 }
		if props.apiVersion >= vk.API_VERSION_1_3 { score += 10 }
		if score > best {
			best = score
			r.phys = d
			r.qfamily = qf
			r.device_name = fmt.aprintf("%s (Vulkan %d.%d.%d, driver %d.%d.%d)",
				cstring(&props.deviceName[0]),
				props.apiVersion >> 22, (props.apiVersion >> 12) & 0x3ff, props.apiVersion & 0xfff,
				props.driverVersion >> 22, (props.driverVersion >> 12) & 0x3ff, props.driverVersion & 0xfff)
		}
	}
	if best < 0 {
		fmt.eprintln("vk: no device with graphics+present for this surface and VK_KHR_swapchain")
		return false
	}
	return true
}

vk_create_device :: proc(r: ^Renderer) -> bool {
	props: vk.PhysicalDeviceProperties
	vk.GetPhysicalDeviceProperties(r.phys, &props)
	use_13 := props.apiVersion >= vk.API_VERSION_1_3 && r.instance_version >= vk.API_VERSION_1_3

	exts := make([dynamic]cstring, context.temp_allocator)
	append(&exts, vk.KHR_SWAPCHAIN_EXTENSION_NAME)

	// Feature query + enable. Vulkan 1.3 promotes dynamic rendering to core;
	// on a 1.2 device we ask for VK_KHR_dynamic_rendering instead.
	f13 := vk.PhysicalDeviceVulkan13Features{sType = .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES}
	fdr := vk.PhysicalDeviceDynamicRenderingFeatures{sType = .PHYSICAL_DEVICE_DYNAMIC_RENDERING_FEATURES}
	f2  := vk.PhysicalDeviceFeatures2{sType = .PHYSICAL_DEVICE_FEATURES_2}
	if use_13 {
		f2.pNext = &f13
	} else {
		if !has_device_ext(r.phys, vk.KHR_DYNAMIC_RENDERING_EXTENSION_NAME) {
			fmt.eprintln("vk: device is <1.3 and lacks VK_KHR_dynamic_rendering")
			return false
		}
		append(&exts, vk.KHR_DYNAMIC_RENDERING_EXTENSION_NAME)
		r.khr_dynamic_rendering = true
		f2.pNext = &fdr
	}
	vk.GetPhysicalDeviceFeatures2(r.phys, &f2)
	if (use_13 && !f13.dynamicRendering) || (!use_13 && !fdr.dynamicRendering) {
		fmt.eprintln("vk: dynamicRendering feature not supported")
		return false
	}
	// Enable only what we use.
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
		fmt.eprintfln("vk: CreateDevice: %v", res)
		return false
	}
	vk.load_proc_addresses_device(r.device)
	vk.GetDeviceQueue(r.device, r.qfamily, 0, &r.queue)

	// Surface format: prefer 8-bit BGRA sRGB, else the first one offered.
	fcount: u32
	vk.GetPhysicalDeviceSurfaceFormatsKHR(r.phys, r.surface, &fcount, nil)
	formats := make([]vk.SurfaceFormatKHR, fcount, context.temp_allocator)
	vk.GetPhysicalDeviceSurfaceFormatsKHR(r.phys, r.surface, &fcount, raw_data(formats))
	r.format = formats[0]
	for f in formats {
		if f.format == .B8G8R8A8_SRGB && f.colorSpace == .SRGB_NONLINEAR { r.format = f; break }
	}
	r.present_mode = .FIFO // always supported

	pool := vk.CommandPoolCreateInfo{
		sType            = .COMMAND_POOL_CREATE_INFO,
		flags            = {.RESET_COMMAND_BUFFER},
		queueFamilyIndex = r.qfamily,
	}
	if res := vk.CreateCommandPool(r.device, &pool, nil, &r.cmd_pool); res != .SUCCESS {
		fmt.eprintfln("vk: CreateCommandPool: %v", res)
		return false
	}
	for i in 0 ..< FRAMES_IN_FLIGHT {
		si := vk.SemaphoreCreateInfo{sType = .SEMAPHORE_CREATE_INFO}
		fi := vk.FenceCreateInfo{sType = .FENCE_CREATE_INFO, flags = {.SIGNALED}}
		vk.CreateSemaphore(r.device, &si, nil, &r.image_available[i])
		vk.CreateFence(r.device, &fi, nil, &r.in_flight[i])
	}
	return true
}

// ---------------------------------------------------------------- pipeline

vk_create_pipeline :: proc(r: ^Renderer) -> bool {
	make_module :: proc(device: vk.Device, code: []u32) -> (m: vk.ShaderModule, ok: bool) {
		info := vk.ShaderModuleCreateInfo{
			sType    = .SHADER_MODULE_CREATE_INFO,
			codeSize = len(code) * size_of(u32),
			pCode    = raw_data(code),
		}
		res := vk.CreateShaderModule(device, &info, nil, &m)
		if res != .SUCCESS { fmt.eprintfln("vk: CreateShaderModule: %v", res) }
		return m, res == .SUCCESS
	}
	vert, vok := make_module(r.device, VERT_SPV)
	frag, fok := make_module(r.device, FRAG_SPV)
	if !vok || !fok { return false }
	defer vk.DestroyShaderModule(r.device, vert, nil)
	defer vk.DestroyShaderModule(r.device, frag, nil)

	layout := vk.PipelineLayoutCreateInfo{sType = .PIPELINE_LAYOUT_CREATE_INFO}
	if res := vk.CreatePipelineLayout(r.device, &layout, nil, &r.pipeline_layout); res != .SUCCESS {
		fmt.eprintfln("vk: CreatePipelineLayout: %v", res)
		return false
	}

	stages := [2]vk.PipelineShaderStageCreateInfo{
		{sType = .PIPELINE_SHADER_STAGE_CREATE_INFO, stage = {.VERTEX},   module = vert, pName = "main"},
		{sType = .PIPELINE_SHADER_STAGE_CREATE_INFO, stage = {.FRAGMENT}, module = frag, pName = "main"},
	}
	vertex_input := vk.PipelineVertexInputStateCreateInfo{sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO}
	assembly := vk.PipelineInputAssemblyStateCreateInfo{
		sType    = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
		topology = .TRIANGLE_LIST,
	}
	viewport := vk.PipelineViewportStateCreateInfo{
		sType         = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
		viewportCount = 1,
		scissorCount  = 1, // dynamic — set per frame so resizes do not rebuild the pipeline
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
	blend_attachment := vk.PipelineColorBlendAttachmentState{
		colorWriteMask = {.R, .G, .B, .A},
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
	color_format := r.format.format
	rendering := vk.PipelineRenderingCreateInfo{
		sType                   = .PIPELINE_RENDERING_CREATE_INFO,
		colorAttachmentCount    = 1,
		pColorAttachmentFormats = &color_format,
	}
	info := vk.GraphicsPipelineCreateInfo{
		sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
		pNext               = &rendering, // no VkRenderPass: dynamic rendering
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
	if res := vk.CreateGraphicsPipelines(r.device, 0, 1, &info, nil, &r.pipeline); res != .SUCCESS {
		fmt.eprintfln("vk: CreateGraphicsPipelines: %v", res)
		return false
	}
	return true
}

// --------------------------------------------------------------- swapchain

@(private="file")
destroy_swapchain_resources :: proc(r: ^Renderer) {
	for v in r.views           { vk.DestroyImageView(r.device, v, nil) }
	for s in r.render_finished { vk.DestroySemaphore(r.device, s, nil) }
	if len(r.cmd_bufs) > 0     { vk.FreeCommandBuffers(r.device, r.cmd_pool, u32(len(r.cmd_bufs)), raw_data(r.cmd_bufs)) }
	delete(r.views); delete(r.render_finished); delete(r.cmd_bufs); delete(r.images); delete(r.image_fence)
	r.views = nil; r.render_finished = nil; r.cmd_bufs = nil; r.images = nil; r.image_fence = nil
}

// Creates the swapchain for `width`x`height` (surface-local pixels); if one
// exists it is replaced (oldSwapchain handoff), so this is also the resize path.
vk_create_swapchain :: proc(r: ^Renderer, width, height: u32) -> bool {
	if r.swapchain != 0 {
		vk.DeviceWaitIdle(r.device)
		destroy_swapchain_resources(r)
	}
	caps: vk.SurfaceCapabilitiesKHR
	if res := vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(r.phys, r.surface, &caps); res != .SUCCESS {
		fmt.eprintfln("vk: GetPhysicalDeviceSurfaceCapabilitiesKHR: %v", res)
		return false
	}
	// Wayland reports currentExtent = 0xFFFFFFFF: the client decides the size.
	extent := vk.Extent2D{
		width  = clamp(width,  caps.minImageExtent.width,  caps.maxImageExtent.width),
		height = clamp(height, caps.minImageExtent.height, caps.maxImageExtent.height),
	}
	if caps.currentExtent.width != max(u32) { extent = caps.currentExtent }

	image_count := caps.minImageCount
	if caps.maxImageCount != 0 { image_count = min(image_count, caps.maxImageCount) }

	composite: vk.CompositeAlphaFlagsKHR = {.OPAQUE}
	if .OPAQUE not_in caps.supportedCompositeAlpha {
		for bit in vk.CompositeAlphaFlagKHR { if bit in caps.supportedCompositeAlpha { composite = {bit}; break } }
	}

	old := r.swapchain
	info := vk.SwapchainCreateInfoKHR{
		sType            = .SWAPCHAIN_CREATE_INFO_KHR,
		surface          = r.surface,
		minImageCount    = image_count,
		imageFormat      = r.format.format,
		imageColorSpace  = r.format.colorSpace,
		imageExtent      = extent,
		imageArrayLayers = 1,
		imageUsage       = {.COLOR_ATTACHMENT},
		imageSharingMode = .EXCLUSIVE,
		preTransform     = caps.currentTransform,
		compositeAlpha   = composite,
		presentMode      = r.present_mode,
		clipped          = true,
		oldSwapchain     = old,
	}
	if res := vk.CreateSwapchainKHR(r.device, &info, nil, &r.swapchain); res != .SUCCESS {
		fmt.eprintfln("vk: CreateSwapchainKHR: %v", res)
		return false
	}
	if old != 0 { vk.DestroySwapchainKHR(r.device, old, nil) }
	r.extent = extent

	count: u32
	vk.GetSwapchainImagesKHR(r.device, r.swapchain, &count, nil)
	r.images = make([]vk.Image, count)
	vk.GetSwapchainImagesKHR(r.device, r.swapchain, &count, raw_data(r.images))
	r.views           = make([]vk.ImageView, count)
	r.render_finished = make([]vk.Semaphore, count)
	r.cmd_bufs        = make([]vk.CommandBuffer, count)
	r.image_fence     = make([]vk.Fence, count)
	for img, i in r.images {
		vi := vk.ImageViewCreateInfo{
			sType            = .IMAGE_VIEW_CREATE_INFO,
			image            = img,
			viewType         = .D2,
			format           = r.format.format,
			subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
		}
		if res := vk.CreateImageView(r.device, &vi, nil, &r.views[i]); res != .SUCCESS {
			fmt.eprintfln("vk: CreateImageView: %v", res)
			return false
		}
		si := vk.SemaphoreCreateInfo{sType = .SEMAPHORE_CREATE_INFO}
		vk.CreateSemaphore(r.device, &si, nil, &r.render_finished[i])
	}
	alloc := vk.CommandBufferAllocateInfo{
		sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
		commandPool        = r.cmd_pool,
		level              = .PRIMARY,
		commandBufferCount = count,
	}
	if res := vk.AllocateCommandBuffers(r.device, &alloc, raw_data(r.cmd_bufs)); res != .SUCCESS {
		fmt.eprintfln("vk: AllocateCommandBuffers: %v", res)
		return false
	}
	return true
}

// ------------------------------------------------------------------- frame

@(private="file")
image_barrier :: proc(
	cb: vk.CommandBuffer, image: vk.Image,
	src_access, dst_access: vk.AccessFlags,
	old_layout, new_layout: vk.ImageLayout,
	src_stage, dst_stage: vk.PipelineStageFlags,
) {
	b := vk.ImageMemoryBarrier{
		sType               = .IMAGE_MEMORY_BARRIER,
		srcAccessMask       = src_access,
		dstAccessMask       = dst_access,
		oldLayout           = old_layout,
		newLayout           = new_layout,
		srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		image               = image,
		subresourceRange    = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
	}
	vk.CmdPipelineBarrier(cb, src_stage, dst_stage, {}, 0, nil, 0, nil, 1, &b)
}

// Records and submits one frame, then presents. `out_of_date` asks the caller
// to recreate the swapchain (nothing was presented in that case).
vk_draw :: proc(r: ^Renderer, t: f32) -> (presented: bool, out_of_date: bool) {
	slot := r.slot
	vk.WaitForFences(r.device, 1, &r.in_flight[slot], true, max(u64))

	img: u32
	acq := vk.AcquireNextImageKHR(r.device, r.swapchain, max(u64), r.image_available[slot], 0, &img)
	if acq == .ERROR_OUT_OF_DATE_KHR { return false, true }
	if acq != .SUCCESS && acq != .SUBOPTIMAL_KHR {
		fmt.eprintfln("vk: AcquireNextImageKHR: %v", acq)
		return false, false
	}
	// The command buffer for this image may still be executing from an
	// earlier slot: wait for that slot's fence before re-recording.
	if r.image_fence[img] != 0 && r.image_fence[img] != r.in_flight[slot] {
		vk.WaitForFences(r.device, 1, &r.image_fence[img], true, max(u64))
	}
	r.image_fence[img] = r.in_flight[slot]
	vk.ResetFences(r.device, 1, &r.in_flight[slot])

	cb := r.cmd_bufs[img]
	vk.ResetCommandBuffer(cb, {})
	begin := vk.CommandBufferBeginInfo{sType = .COMMAND_BUFFER_BEGIN_INFO, flags = {.ONE_TIME_SUBMIT}}
	vk.BeginCommandBuffer(cb, &begin)

	image_barrier(cb, r.images[img],
		{}, {.COLOR_ATTACHMENT_WRITE},
		.UNDEFINED, .COLOR_ATTACHMENT_OPTIMAL,
		{.TOP_OF_PIPE}, {.COLOR_ATTACHMENT_OUTPUT})

	// Slowly breathing background so a screenshot proves frames are live.
	bg := 0.10 + 0.05 * (0.5 + 0.5 * sin_approx(t))
	attach := vk.RenderingAttachmentInfo{
		sType       = .RENDERING_ATTACHMENT_INFO,
		imageView   = r.views[img],
		imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
		loadOp      = .CLEAR,
		storeOp     = .STORE,
		clearValue  = {color = {float32 = {bg, bg, bg + 0.04, 1}}},
	}
	ri := vk.RenderingInfo{
		sType                = .RENDERING_INFO,
		renderArea           = {extent = r.extent},
		layerCount           = 1,
		colorAttachmentCount = 1,
		pColorAttachments    = &attach,
	}
	if r.khr_dynamic_rendering { vk.CmdBeginRenderingKHR(cb, &ri) } else { vk.CmdBeginRendering(cb, &ri) }

	vp := vk.Viewport{width = f32(r.extent.width), height = f32(r.extent.height), minDepth = 0, maxDepth = 1}
	sc := vk.Rect2D{extent = r.extent}
	vk.CmdSetViewport(cb, 0, 1, &vp)
	vk.CmdSetScissor(cb, 0, 1, &sc)
	vk.CmdBindPipeline(cb, .GRAPHICS, r.pipeline)
	vk.CmdDraw(cb, 3, 1, 0, 0)

	if r.khr_dynamic_rendering { vk.CmdEndRenderingKHR(cb) } else { vk.CmdEndRendering(cb) }

	image_barrier(cb, r.images[img],
		{.COLOR_ATTACHMENT_WRITE}, {},
		.COLOR_ATTACHMENT_OPTIMAL, .PRESENT_SRC_KHR,
		{.COLOR_ATTACHMENT_OUTPUT}, {.BOTTOM_OF_PIPE})
	vk.EndCommandBuffer(cb)

	wait_stage: vk.PipelineStageFlags = {.COLOR_ATTACHMENT_OUTPUT}
	submit := vk.SubmitInfo{
		sType                = .SUBMIT_INFO,
		waitSemaphoreCount   = 1,
		pWaitSemaphores      = &r.image_available[slot],
		pWaitDstStageMask    = &wait_stage,
		commandBufferCount   = 1,
		pCommandBuffers      = &cb,
		signalSemaphoreCount = 1,
		pSignalSemaphores    = &r.render_finished[img],
	}
	if res := vk.QueueSubmit(r.queue, 1, &submit, r.in_flight[slot]); res != .SUCCESS {
		fmt.eprintfln("vk: QueueSubmit: %v", res)
		return false, false
	}
	present := vk.PresentInfoKHR{
		sType              = .PRESENT_INFO_KHR,
		waitSemaphoreCount = 1,
		pWaitSemaphores    = &r.render_finished[img],
		swapchainCount     = 1,
		pSwapchains        = &r.swapchain,
		pImageIndices      = &img,
	}
	pres := vk.QueuePresentKHR(r.queue, &present)
	r.slot = (slot + 1) % FRAMES_IN_FLIGHT
	if pres == .SUCCESS || pres == .SUBOPTIMAL_KHR {
		r.frames_presented += 1
		return true, pres == .SUBOPTIMAL_KHR
	}
	if pres == .ERROR_OUT_OF_DATE_KHR { return false, true }
	fmt.eprintfln("vk: QueuePresentKHR: %v", pres)
	return false, false
}

@(private="file")
sin_approx :: proc(x: f32) -> f32 {
	// Cheap sine via Bhaskara; good enough for a background pulse.
	xx := x
	for xx > 6.2831853 { xx -= 6.2831853 }
	sign: f32 = 1
	if xx > 3.1415927 { xx -= 3.1415927; sign = -1 }
	return sign * 16 * xx * (3.1415927 - xx) / (5 * 3.1415927 * 3.1415927 - 4 * xx * (3.1415927 - xx))
}

// ---------------------------------------------------------------- teardown

vk_shutdown :: proc(r: ^Renderer) {
	if r.device != nil {
		vk.DeviceWaitIdle(r.device)
		destroy_swapchain_resources(r)
		if r.swapchain != 0 { vk.DestroySwapchainKHR(r.device, r.swapchain, nil) }
		if r.pipeline != 0 { vk.DestroyPipeline(r.device, r.pipeline, nil) }
		if r.pipeline_layout != 0 { vk.DestroyPipelineLayout(r.device, r.pipeline_layout, nil) }
		for i in 0 ..< FRAMES_IN_FLIGHT {
			if r.image_available[i] != 0 { vk.DestroySemaphore(r.device, r.image_available[i], nil) }
			if r.in_flight[i] != 0 { vk.DestroyFence(r.device, r.in_flight[i], nil) }
		}
		if r.cmd_pool != 0 { vk.DestroyCommandPool(r.device, r.cmd_pool, nil) }
		vk.DestroyDevice(r.device, nil)
	}
	if r.instance != nil {
		if r.surface != 0 { vk.DestroySurfaceKHR(r.instance, r.surface, nil) }
		if r.messenger != 0 && vk.DestroyDebugUtilsMessengerEXT != nil { vk.DestroyDebugUtilsMessengerEXT(r.instance, r.messenger, nil) }
		vk.DestroyInstance(r.instance, nil)
	}
	if r.lib != nil { dynlib.unload_library(r.lib) }
}
