#+build !darwin
// renderer.odin — the Renderer struct, Vulkan loader bootstrap, instance
// creation (+ validation when installed), teardown, and the small memory /
// buffer helpers shared by the other files.
//
// File map:
//   renderer.odin  Renderer, init, destroy, instance, buffers, error sink
//   device.odin    physical-device pick, device/queue, shared GPU objects, pipeline
//   target.odin    targets + swapchain lifecycle (add / resize / remove)
//   atlas.odin     atlas pages, staged uploads, descriptor sets
//   render.odin    render(): commands → batches → record / submit / present
package gpu

import "base:runtime"
import "core:dynlib"
import "core:fmt"
import "core:os"
import vk "vendor:vulkan"

// FRAMES_IN_FLIGHT is the number of frames the CPU may run ahead of the GPU
// per target. Each slot owns a fence, an acquire semaphore, a command buffer
// and a host-visible vertex buffer.
FRAMES_IN_FLIGHT :: 2

// The Vulkan loader is an OS/driver-provided shared library opened at
// runtime; nothing is linked at build time, as the dependency rule requires.
when ODIN_OS == .Windows {
	LOADER_NAME :: "vulkan-1.dll"
} else when ODIN_OS == .Darwin {
	LOADER_NAME :: "libvulkan.dylib"
} else {
	LOADER_NAME :: "libvulkan.so.1"
}

VALIDATION_LAYER :: "VK_LAYER_KHRONOS_validation"

// Renderer owns everything Vulkan: loader, instance, one device + queue, the
// shared pipeline objects, every target's swapchain and every atlas page.
// Zero value = not initialised. Never copy it; pass ^Renderer.
Renderer :: struct {
	// ---- loader + instance (init)
	lib:                 dynlib.Library,
	inst:                vk.Instance,
	instance_version:    u32, // apiVersion the instance was created with (1.3 or 1.2)
	messenger:           vk.DebugUtilsMessengerEXT,
	validation:          bool, // VK_LAYER_KHRONOS_validation + VK_EXT_debug_utils enabled
	validation_errors:   int,  // ERROR-severity messages seen (CI can fail on > 0)
	validation_warnings: int,
	has_surface_caps2:   bool, // VK_KHR_get_surface_capabilities2 enabled

	// ---- device (created by the first target_add)
	phys:                    vk.PhysicalDevice,
	device:                  vk.Device,
	device_name:             string, // "<name> (Vulkan x.y.z, driver …)", owned
	qfamily:                 u32,    // graphics + present family
	queue:                   vk.Queue,
	khr_dynamic_rendering:   bool, // 1.2 device: VK_KHR_dynamic_rendering instead of core 1.3
	has_incremental_present: bool, // VK_KHR_incremental_present enabled → damage is passed to present; BALDR_NO_INCREMENTAL_PRESENT=1 keeps it off
	portability_subset:      bool, // MoltenVK: VK_KHR_portability_subset was enabled
	mem_props:               vk.PhysicalDeviceMemoryProperties,
	max_image_dim:           u32,

	cmd_pool:        vk.CommandPool,
	desc_layout:     vk.DescriptorSetLayout,   // set 0, binding 0: combined image sampler
	desc_pools:      [dynamic]vk.DescriptorPool, // grown on demand
	sampler:         vk.Sampler,               // linear, clamp to edge
	mip_sampler:     vk.Sampler,               // the same, trilinear across a picture's mip levels
	blit_mips:       bool,                     // RGBA8 sRGB can be blitted with a linear filter: pictures get mip levels
	pipeline_layout: vk.PipelineLayout,        // desc_layout + 8-byte push constant (viewport px)
	pipelines:       [dynamic]Pipeline_Entry,  // one pipeline per swapchain colour format
	blur_layout:     vk.PipelineLayout,        // desc_layout + 16-byte fragment push constant (blur.odin)
	blur_pipeline:   vk.Pipeline,              // Kawase pass into BLUR_FORMAT targets
	present_layout:    vk.PipelineLayout,       // desc_layout + 8-byte fragment push constant (present.odin)
	present_pipelines: [dynamic]Pipeline_Entry, // a transparent target's present pass, per swapchain format
	cur_blur_set:    vk.DescriptorSet,         // blurred scene bound for BLUR_PAGE draws during a render

	targets: [MAX_TARGETS]Target_State, // Target = index + 1
	pages:   [dynamic]Page_State,       // Page   = index + 1; pages[0] is WHITE_PAGE
	uploads: [dynamic]Upload,           // staged atlas copies, drained by the next render()
	// canvases (canvas.odin): queued work, batches in flight, what each format can do
	canvas_ops:        [dynamic]Canvas_Op,
	canvas_batches:    [dynamic]^Canvas_Batch,
	staging:           Staging, // staging buffers kept to be used again (canvas_staging.odin)
	dmabuf:            Dmabuf_State, // importing GPU buffers from other processes (dmabuf_*.odin)
	submits:           u64,          // every frame submitted, counted: a frame's serial
	writing:           bool,    // a canvas_write_begin is open (canvas_queue.odin)
	writing_said:      bool,    // …and one was left open: said once, not once a frame
	canvas_next_batch: u64,
	canvas_next_read:  u32,
	canvas_formats:    bit_set[Canvas_Format],
	canvas_filtered:   bit_set[Canvas_Format],
	canvas_memory:     u64,
	nearest_sampler:   vk.Sampler, // a canvas whose format the device cannot filter
	canvas_scratch:    [2][Canvas_Format]Page,     // work copies per format: 0 a blend's backdrop or a filter's input, 1 a blur's first pass (canvas.odin)
	lost:              bool,                       // the device has gone (a reset): recover.odin
	lost_logged:       bool,                       // …and the loss has been reported: logged once, not once a frame
	recoveries_failed: int,                        // …and how many attempts in a row have not brought it back
	generation:        u64,                        // how many times the device has been rebuilt; a Page from before is nothing
	blend_layout:      vk.PipelineLayout,          // three textures and Blend_Push
	blend_pipelines:   [Canvas_Format]vk.Pipeline, // the blend pass, per format
	transform_layout:    vk.PipelineLayout,          // three textures and Transform_Push
	transform_pipelines: [Canvas_Format]vk.Pipeline, // the transform pass, per format
	filter_layout:     vk.PipelineLayout,          // two textures and Filter_Push
	filter_pipelines:  [Canvas_Format]vk.Pipeline, // the filter passes, per format
	dab_layout:        vk.PipelineLayout,          // a brush tip and Dab_Push
	dab_pipelines:     [Canvas_Format]vk.Pipeline, // brush dabs, per format
	stroke_layout:     vk.PipelineLayout,          // Stroke_Push; no descriptor set, there is no texture
	stroke_pipelines:  [Canvas_Format]vk.Pipeline, // variable-width strokes, per format
	canvas_storage:    bit_set[Canvas_Format],     // formats a compute shader can write
	shaders:           [dynamic]Shader_State,      // apps' shaders (shader.odin); Shader = index + 1
	storage_layout:    vk.DescriptorSetLayout,     // a compute shader's destination: one storage image
	storage_pools:     [dynamic]vk.DescriptorPool,

	// ---- per-render scratch (kept allocated between frames)
	verts:   [dynamic]Vertex,
	batches: [dynamic]Batch,
	clips:   [dynamic][4]f32,
	rects:   [dynamic]vk.RectLayerKHR,

	// last_error is the most recent failure message (owned; valid until the
	// next failure; destroy keeps it, a later init's failure replaces it).
	last_error: string,
	// target_fault says why the last target_add failed (api.odin): the
	// caller's cue to stop trying a drawable that will never present.
	target_fault: Target_Fault,
	// frames counts successful presents across all targets.
	frames:     u64,
}

// Pipeline_Entry caches the graphics pipeline built for one colour format.
Pipeline_Entry :: struct {
	format:   vk.Format,
	pipeline: vk.Pipeline,
}

// Buffer is a VkBuffer with its own allocation; host-visible ones stay mapped.
Buffer :: struct {
	buf:  vk.Buffer,
	mem:  vk.DeviceMemory,
	size: int,
	ptr:  rawptr,     // nil for device-local buffers
	use:  Buffer_Use, // what it was made for, so a returned one finds its pool (canvas_staging.odin)
}

// ------------------------------------------------------------------- errors

// fail records `msg` as r.last_error, echoes it to stderr with a "gpu:" prefix
// and returns false so call sites can `return fail(r, ...)`.
@(private)
fail :: proc(r: ^Renderer, msg: string, args: ..any) -> bool {
	delete(r.last_error)
	r.last_error = fmt.aprintf(msg, ..args)
	fmt.eprintfln("gpu: %s", r.last_error)
	return false
}

// validation_wanted says whether to ask for VK_LAYER_KHRONOS_validation:
// yes in a debug build below -o:speed, and BALDR_VALIDATE=1 / =0 decides
// outright. The layer checks what a driver forgives, but costs real time, so
// a build made to be timed must not carry it. It reads the optimisation
// level, not ODIN_DEBUG alone, because `BALDR_FAST=1` passes -o:speed and
// keeps -debug.
@(private)
validation_wanted :: proc() -> bool {
	switch os.get_env("BALDR_VALIDATE", context.temp_allocator) {
	case "1", "true", "yes": return true
	case "0", "false", "no":  return false
	}
	return ODIN_DEBUG && ODIN_OPTIMIZATION_MODE < .Speed
}

// -------------------------------------------------------------------- init

// init opens the Vulkan loader, loads the global entry points, creates the
// instance with VK_KHR_surface + `instance_exts` (the platform's
// VK_KHR_*_surface) + VK_KHR_get_surface_capabilities2 when available, turns
// on VK_LAYER_KHRONOS_validation and VK_EXT_debug_utils when they are
// installed (WARNING/ERROR messages go to stderr and are counted in
// r.validation_errors / r.validation_warnings), and loads the instance-level
// procs into vendor:vulkan's package-global tables.
//
// Fails (ok = false, why = human-readable reason) when there is no loader, no
// Vulkan ≥ 1.2, or a requested extension is missing. Calling init twice on an
// initialised renderer is a no-op returning true.
init :: proc(r: ^Renderer, instance_exts: []cstring, app_name: cstring) -> (ok: bool, why: string) {
	if r.inst != nil { return true, "" }

	lib, lok := dynlib.load_library(LOADER_NAME)
	if !lok {
		fail(r, "cannot load %s: %s", LOADER_NAME, dynlib.last_error())
		return false, r.last_error
	}
	r.lib = lib
	gipa, found := dynlib.symbol_address(lib, "vkGetInstanceProcAddr")
	if !found || gipa == nil {
		fail(r, "%s has no vkGetInstanceProcAddr", LOADER_NAME)
		destroy(r)
		return false, r.last_error
	}
	vk.load_proc_addresses_global(gipa)
	if vk.CreateInstance == nil || vk.EnumerateInstanceExtensionProperties == nil {
		fail(r, "Vulkan global entry points missing")
		destroy(r)
		return false, r.last_error
	}

	loader_version: u32 = vk.API_VERSION_1_0
	if vk.EnumerateInstanceVersion != nil {
		vk.EnumerateInstanceVersion(&loader_version)
	}
	if loader_version < vk.API_VERSION_1_2 {
		fail(r, "Vulkan loader only supports %d.%d; 1.2 is required", loader_version >> 22, (loader_version >> 12) & 0x3ff)
		destroy(r)
		return false, r.last_error
	}
	r.instance_version = vk.API_VERSION_1_3 if loader_version >= vk.API_VERSION_1_3 else vk.API_VERSION_1_2

	exts := make([dynamic]cstring, context.temp_allocator)
	append(&exts, vk.KHR_SURFACE_EXTENSION_NAME)
	if !has_instance_ext(vk.KHR_SURFACE_EXTENSION_NAME) {
		fail(r, "VK_KHR_surface not available")
		destroy(r)
		return false, r.last_error
	}
	for e in instance_exts {
		if !has_instance_ext(string(e)) {
			fail(r, "instance extension %s not available", e)
			destroy(r)
			return false, r.last_error
		}
		if !contains_cstring(exts[:], e) { append(&exts, e) }
	}
	if has_instance_ext(vk.KHR_GET_SURFACE_CAPABILITIES_2_EXTENSION_NAME) {
		append(&exts, vk.KHR_GET_SURFACE_CAPABILITIES_2_EXTENSION_NAME)
		r.has_surface_caps2 = true
	}
	flags: vk.InstanceCreateFlags
	when ODIN_OS == .Darwin {
		// MoltenVK is a portability implementation: it is only enumerated when asked.
		if has_instance_ext(vk.KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME) {
			append(&exts, vk.KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME)
			flags = {.ENUMERATE_PORTABILITY_KHR}
		}
	}
	layers := make([dynamic]cstring, context.temp_allocator)
	if validation_wanted() && has_layer(VALIDATION_LAYER) && has_instance_ext(vk.EXT_DEBUG_UTILS_EXTENSION_NAME) {
		append(&layers, VALIDATION_LAYER)
		append(&exts, vk.EXT_DEBUG_UTILS_EXTENSION_NAME)
		r.validation = true
		// Said every time: a clean log and a log where the layer never loaded
		// look alike, so without this line a run proves nothing.
		fmt.eprintln("gpu: the Vulkan validation layer is on (debug build; BALDR_VALIDATE=0 turns it off)")
	}

	app := vk.ApplicationInfo{
		sType              = .APPLICATION_INFO,
		pApplicationName   = app_name,
		applicationVersion = vk.MAKE_VERSION(0, 1, 0),
		pEngineName        = "baldr",
		engineVersion      = vk.MAKE_VERSION(0, 1, 0),
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
		pNext                   = &dbg if r.validation else nil, // also catches CreateInstance-time messages
		flags                   = flags,
		pApplicationInfo        = &app,
		enabledLayerCount       = u32(len(layers)),
		ppEnabledLayerNames     = raw_data(layers),
		enabledExtensionCount   = u32(len(exts)),
		ppEnabledExtensionNames = raw_data(exts),
	}
	if res := vk.CreateInstance(&info, nil, &r.inst); res != .SUCCESS {
		r.inst = nil
		fail(r, "vkCreateInstance: %v", res)
		destroy(r)
		return false, r.last_error
	}
	vk.load_proc_addresses_instance(r.inst)
	if r.validation && vk.CreateDebugUtilsMessengerEXT != nil {
		if res := vk.CreateDebugUtilsMessengerEXT(r.inst, &dbg, nil, &r.messenger); res != .SUCCESS {
			fmt.eprintfln("gpu: vkCreateDebugUtilsMessengerEXT: %v (continuing without messenger)", res)
			r.messenger = 0
		}
	}
	return true, ""
}

// instance returns the VkInstance so the platform backend can create its
// VkSurfaceKHR (vkCreate*SurfaceKHR procs are loaded by init). nil before init.
instance :: proc(r: ^Renderer) -> vk.Instance {
	return r.inst
}

// destroy waits for the device to go idle, then releases every target,
// page, pipeline, the device, the debug messenger, the instance and the
// loader library. The Renderer is zeroed and may be init'ed again.
destroy :: proc(r: ^Renderer) {
	if r.device != nil {
		vk.DeviceWaitIdle(r.device)
		canvas_shutdown(r)
		dmabuf_shutdown(r)
		for &t in r.targets {
			if t.used { target_state_destroy(r, &t) }
		}
		for &p in r.pages {
			if p.used { page_state_destroy(r, &p) }
		}
		for &u in r.uploads { buffer_destroy(r, &u.staging) }
		for e in r.pipelines { vk.DestroyPipeline(r.device, e.pipeline, nil) }
		if r.pipeline_layout != 0 { vk.DestroyPipelineLayout(r.device, r.pipeline_layout, nil) }
		if r.blur_pipeline != 0 { vk.DestroyPipeline(r.device, r.blur_pipeline, nil) }
		if r.blur_layout != 0 { vk.DestroyPipelineLayout(r.device, r.blur_layout, nil) }
		for e in r.present_pipelines { vk.DestroyPipeline(r.device, e.pipeline, nil) }
		if r.present_layout != 0 { vk.DestroyPipelineLayout(r.device, r.present_layout, nil) }
		if r.sampler != 0 { vk.DestroySampler(r.device, r.sampler, nil) }
		if r.mip_sampler != 0 { vk.DestroySampler(r.device, r.mip_sampler, nil) }
		if r.nearest_sampler != 0 { vk.DestroySampler(r.device, r.nearest_sampler, nil) }
		for pool in r.desc_pools { vk.DestroyDescriptorPool(r.device, pool, nil) }
		if r.desc_layout != 0 { vk.DestroyDescriptorSetLayout(r.device, r.desc_layout, nil) }
		if r.cmd_pool != 0 { vk.DestroyCommandPool(r.device, r.cmd_pool, nil) }
		vk.DestroyDevice(r.device, nil)
	} else if r.inst != nil {
		// Targets added before a device exists cannot happen (target_add
		// creates the device), but surfaces handed to a failed target_add can.
		for &t in r.targets {
			if t.used && t.surface != 0 { vk.DestroySurfaceKHR(r.inst, t.surface, nil) }
		}
	}
	if r.validation && r.validation_errors + r.validation_warnings > 0 {
		fmt.eprintfln("gpu: the validation layer reported %d error(s) and %d warning(s) this run",
			r.validation_errors, r.validation_warnings)
	}
	if r.inst != nil {
		if r.messenger != 0 && vk.DestroyDebugUtilsMessengerEXT != nil {
			vk.DestroyDebugUtilsMessengerEXT(r.inst, r.messenger, nil)
		}
		vk.DestroyInstance(r.inst, nil)
	}
	if r.lib != nil { dynlib.unload_library(r.lib) }

	delete(r.desc_pools)
	delete(r.pipelines)
	delete(r.present_pipelines)
	delete(r.pages)
	delete(r.uploads)
	delete(r.verts)
	delete(r.batches)
	delete(r.clips)
	delete(r.rects)
	delete(r.device_name)
	last_error := r.last_error // survives destroy so init's failure path can return it
	r^ = {}
	r.last_error = last_error
}

// ------------------------------------------------------------ enumeration

@(private)
contains_cstring :: proc(list: []cstring, s: cstring) -> bool {
	for e in list {
		if string(e) == string(s) { return true }
	}
	return false
}

@(private)
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

@(private)
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

@(private)
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

// debug_callback counts and prints every validation message. There is no
// known-noise list: every message is a fault. When one names a number, check
// what the constant actually is before explaining why the layer is wrong.
@(private)
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
	fmt.eprintfln("gpu: validation %v %v: %s", severity, types, data.pMessage)
	return false
}

// ------------------------------------------------------------------ memory

@(private)
find_memory_type :: proc(r: ^Renderer, type_bits: u32, want: vk.MemoryPropertyFlags) -> (u32, bool) {
	for i in 0 ..< r.mem_props.memoryTypeCount {
		if type_bits & (u32(1) << i) != 0 && r.mem_props.memoryTypes[i].propertyFlags >= want {
			return i, true
		}
	}
	return 0, false
}

// buffer_create makes a buffer with a dedicated allocation. `host` selects
// HOST_VISIBLE | HOST_COHERENT memory (persistently mapped into b.ptr);
// otherwise DEVICE_LOCAL.
@(private)
buffer_create :: proc(r: ^Renderer, size: int, usage: vk.BufferUsageFlags, host: bool) -> (b: Buffer, ok: bool) {
	info := vk.BufferCreateInfo{
		sType       = .BUFFER_CREATE_INFO,
		size        = vk.DeviceSize(size),
		usage       = usage,
		sharingMode = .EXCLUSIVE,
	}
	if res := vk.CreateBuffer(r.device, &info, nil, &b.buf); res != .SUCCESS {
		fail(r, "vkCreateBuffer(%d bytes): %v", size, res)
		return {}, false
	}
	req: vk.MemoryRequirements
	vk.GetBufferMemoryRequirements(r.device, b.buf, &req)
	want: vk.MemoryPropertyFlags = {.HOST_VISIBLE, .HOST_COHERENT} if host else {.DEVICE_LOCAL}
	type_index, found := find_memory_type(r, req.memoryTypeBits, want)
	if !found && !host {
		type_index, found = find_memory_type(r, req.memoryTypeBits, {})
	}
	if !found {
		fail(r, "no suitable memory type for buffer")
		vk.DestroyBuffer(r.device, b.buf, nil)
		return {}, false
	}
	alloc := vk.MemoryAllocateInfo{
		sType           = .MEMORY_ALLOCATE_INFO,
		allocationSize  = req.size,
		memoryTypeIndex = type_index,
	}
	if res := vk.AllocateMemory(r.device, &alloc, nil, &b.mem); res != .SUCCESS {
		fail(r, "vkAllocateMemory(%d bytes): %v", req.size, res)
		vk.DestroyBuffer(r.device, b.buf, nil)
		return {}, false
	}
	if res := vk.BindBufferMemory(r.device, b.buf, b.mem, 0); res != .SUCCESS {
		fail(r, "vkBindBufferMemory: %v", res)
		vk.FreeMemory(r.device, b.mem, nil)
		vk.DestroyBuffer(r.device, b.buf, nil)
		return {}, false
	}
	if host {
		if res := vk.MapMemory(r.device, b.mem, 0, vk.DeviceSize(vk.WHOLE_SIZE), {}, &b.ptr); res != .SUCCESS {
			fail(r, "vkMapMemory: %v", res)
			vk.FreeMemory(r.device, b.mem, nil)
			vk.DestroyBuffer(r.device, b.buf, nil)
			return {}, false
		}
	}
	b.size = size
	return b, true
}

@(private)
buffer_destroy :: proc(r: ^Renderer, b: ^Buffer) {
	// No device: nothing was made and the entry points below are not loaded,
	// so calling one would crash. This lets canvas_staging.odin's policy be
	// tested headlessly.
	if r.device == nil { b^ = {}; return }
	if b.ptr != nil { vk.UnmapMemory(r.device, b.mem) }
	if b.buf != 0 { vk.DestroyBuffer(r.device, b.buf, nil) }
	if b.mem != 0 { vk.FreeMemory(r.device, b.mem, nil) }
	b^ = {}
}
