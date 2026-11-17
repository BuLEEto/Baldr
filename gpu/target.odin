#+build !darwin
// target.odin — a Target is one presentable VkSurfaceKHR with its own
// swapchain, per-image present semaphores and per-frame-in-flight
// fence / acquire semaphore / command buffer / vertex buffer.
//
// Swapchain policy: FIFO, imageCount =
// caps.minImageCount exactly, B8G8R8A8_SRGB preferred (else any sRGB, else
// the first format) for an opaque target and B8G8R8A8_UNORM for a
// transparent one, which draws into a scene of its own and presents it
// through the present pass (present.odin); composite alpha
// PRE_MULTIPLIED/INHERIT for transparent targets and OPAQUE otherwise,
// oldSwapchain handoff on resize.
package gpu

import vk "vendor:vulkan"

// Target_State is the renderer-side record for one Target.
Target_State :: struct {
	used:        bool,
	surface:     vk.SurfaceKHR,
	transparent: bool,
	size_px:     [2]u32, // requested size; used when the surface lets the client choose (Wayland)
	format:      vk.SurfaceFormatKHR,
	pipeline:    vk.Pipeline, // pipeline for `format` (cached in r.pipelines, not owned here)

	swapchain:       vk.SwapchainKHR, // 0 when the extent is zero (minimised / not yet sized)
	extent:          vk.Extent2D,
	retired:         [2]vk.SwapchainKHR, // the ones recreations replaced after they had presented, newest first: kept until the new one has presented twice, so the compositor always has a picture
	presents:        u32,                // pictures the current swapchain has presented
	images:          []vk.Image,
	views:           []vk.ImageView,
	render_finished: []vk.Semaphore, // per image: present waits on it
	image_fence:     []vk.Fence,     // per image: the slot fence that last drew into it (0 = never)

	frames: [FRAMES_IN_FLIGHT]Frame,
	slot:   u32,
	lost:   bool, // VK_ERROR_SURFACE_LOST_KHR seen; caller should target_remove

	can_blit: bool,       // swapchain images have TRANSFER_SRC (needed by Backdrop on an opaque target)
	blur:     Blur_State, // quarter-res ping-pong images for Backdrop; sized to `extent`

	// A transparent target draws into its scene, which the present pass
	// writes to the swapchain as the compositor reads it (present.odin).
	scene:            Sampled_Image,
	present:          Present_Mode,
	present_pipeline: vk.Pipeline,
}

// Frame is one frame-in-flight slot.
Frame :: struct {
	cmd:             vk.CommandBuffer,
	fence:           vk.Fence,
	image_available: vk.Semaphore,
	vbuf:            Buffer,           // host-visible vertex ring, grown on demand
	retire:          [dynamic]Buffer,  // staging buffers freed once this slot's fence signals again
	serial:          u64,              // which submit this slot is holding (dmabuf_*.odin: has it finished?)
	sems:            [dynamic]vk.Semaphore, // acquire fences this submit waits on, handed back when it signals
}

@(private)
Swapchain_Result :: enum u8 { OK, Zero, Lost, Error }

@(private)
target_state :: proc(r: ^Renderer, t: Target) -> ^Target_State {
	i := int(t) - 1
	if i < 0 || i >= MAX_TARGETS || !r.targets[i].used { return nil }
	return &r.targets[i]
}

// target_frames_create makes a target's per-frame semaphores, fences and
// command buffers: what target_add needs on a new one and target_restore
// needs on one whose device went.
@(private)
target_frames_create :: proc(r: ^Renderer, ts: ^Target_State) -> bool {
	for &f in ts.frames {
		si := vk.SemaphoreCreateInfo{sType = .SEMAPHORE_CREATE_INFO}
		fi := vk.FenceCreateInfo{sType = .FENCE_CREATE_INFO, flags = {.SIGNALED}}
		ai := vk.CommandBufferAllocateInfo{
			sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
			commandPool        = r.cmd_pool,
			level              = .PRIMARY,
			commandBufferCount = 1,
		}
		if vk.CreateSemaphore(r.device, &si, nil, &f.image_available) != .SUCCESS ||
		   vk.CreateFence(r.device, &fi, nil, &f.fence) != .SUCCESS ||
		   vk.AllocateCommandBuffers(r.device, &ai, &f.cmd) != .SUCCESS {
			return false
		}
	}
	return true
}

// target_pipelines_create gives the target the pipelines it draws and
// presents with, for its surface format. Both live in the renderer's caches,
// shared by every target of that format, so the target does not own them,
// and a restored target must ask again: the caches went with the device.
@(private)
target_pipelines_create :: proc(r: ^Renderer, ts: ^Target_State) -> bool {
	pipeline, pok := pipeline_for_format(r, SCENE_FORMAT if ts.transparent else ts.format.format)
	if !pok do return false
	ts.pipeline = pipeline
	if ts.transparent {
		present, prok := present_pipeline_for(r, ts.format.format)
		if !prok do return false
		ts.present_pipeline = present
	}
	return true
}

// target_restore builds a target again in the slot it had, after a device
// was lost and made anew (recover.odin): an app's Target handle is that
// slot, so it must stay the same or every window it names moves.
@(private)
target_restore :: proc(r: ^Renderer, slot: int, surface: vk.SurfaceKHR, size_px: [2]u32, transparent: bool) -> bool {
	if slot < 0 || slot >= MAX_TARGETS || r.device == nil do return false
	ts := &r.targets[slot]
	ts^ = {used = true, surface = surface, transparent = transparent, size_px = size_px}
	if !target_frames_create(r, ts) || !choose_surface_format(r, ts) || !target_pipelines_create(r, ts) {
		return target_keep_lost(r, ts, surface, size_px, transparent)
	}
	switch swapchain_create(r, ts) {
	case .OK, .Zero: return true
	case .Lost, .Error:
		return target_keep_lost(r, ts, surface, size_px, transparent)
	}
	return true
}

// target_fail clears a slot target_add could not finish and keeps the
// surface: a drawable becomes the renderer's only when target_add returns
// true. Destroying it here would leave the caller retrying with a handle the
// driver had freed, a crash inside the WSI.
@(private)
target_fail :: proc(r: ^Renderer, ts: ^Target_State, fault: Target_Fault) -> bool {
	ts.surface = 0 // withheld from the teardown: it is the caller's still
	target_state_destroy(r, ts)
	r.target_fault = fault
	return false
}

// target_keep_lost is the same for a restore that did not finish, except
// that this surface is the renderer's: the app's Target names this slot and
// the recovery is still going. So the slot keeps the surface and what it
// would be rebuilt from, marked lost: render answers .Lost, the next attempt
// has everything it needs, and target_remove still has a surface to destroy.
@(private)
target_keep_lost :: proc(r: ^Renderer, ts: ^Target_State, surface: vk.SurfaceKHR, size_px: [2]u32, transparent: bool) -> bool {
	ts.surface = 0
	target_state_destroy(r, ts)
	ts^ = {used = true, surface = surface, size_px = size_px, transparent = transparent, lost = true}
	return false
}

// target_add registers `surface` (created by the platform backend with
// gpu.instance) and builds its swapchain at `size_px`. The first call also
// picks the physical device that can present to this surface and creates
// the device, queue and pipeline objects; later surfaces must be presentable
// from the same queue family. `transparent` selects a composite-alpha mode
// that lets the clear/draw alpha show the desktop behind the window, and
// presents through a scene converted for the compositor (present.odin).
//
// The renderer takes ownership of the VkSurfaceKHR when it returns true:
// target_remove (or destroy) destroys it. A call that returns false has not
// taken it and has not touched it — it is the caller's to try again with, or
// to let go of through drawable_release. A zero-size `size_px` is allowed (no
// swapchain yet; render returns .Skipped until target_resize gives it a
// size). Fails when MAX_TARGETS are in use, the device cannot be created, or
// the surface is not presentable; `target_fault` says which of those it was,
// and .Slots is the only one worth retrying.
target_add :: proc(r: ^Renderer, drawable: Drawable, size_px: [2]u32, transparent: bool) -> (Target, bool) {
	surface := vk.SurfaceKHR(drawable) // the neutral handle is a VkSurfaceKHR here
	r.target_fault = .None
	if r.inst == nil { r.target_fault = .Drawable; fail(r, "target_add before init"); return 0, false }
	if surface == 0 { r.target_fault = .Drawable; fail(r, "target_add: null surface"); return 0, false }
	if r.device == nil {
		if !device_create(r, surface) { r.target_fault = .Device; return 0, false }
	} else {
		present_ok: b32
		vk.GetPhysicalDeviceSurfaceSupportKHR(r.phys, r.qfamily, surface, &present_ok)
		if !present_ok {
			r.target_fault = .Surface
			fail(r, "target_add: surface not presentable from queue family %d", r.qfamily)
			return 0, false
		}
	}
	slot := -1
	for &t, i in r.targets {
		if !t.used { slot = i; break }
	}
	if slot < 0 { r.target_fault = .Slots; fail(r, "target_add: MAX_TARGETS (%d) in use", MAX_TARGETS); return 0, false }

	ts := &r.targets[slot]
	ts^ = {used = true, surface = surface, transparent = transparent, size_px = size_px}

	if !target_frames_create(r, ts) {
		fail(r, "target_add: cannot create per-frame objects")
		return 0, target_fail(r, ts, .Objects)
	}

	// choose_surface_format asks the surface itself, and says what it
	// answered (no formats, surface lost): that is a fact about this
	// *surface*, not about the slot or the device, and no retry changes it.
	if !choose_surface_format(r, ts) { return 0, target_fail(r, ts, .Surface) }
	if !target_pipelines_create(r, ts) {
		fail(r, "target_add: no pipeline for %v", ts.format.format)
		return 0, target_fail(r, ts, .Objects)
	}

	switch swapchain_create(r, ts) {
	case .OK, .Zero:
		return Target(slot + 1), true
	case .Lost:  return 0, target_fail(r, ts, .Surface)
	case .Error: return 0, target_fail(r, ts, .Objects)
	}
	return 0, false
}

// target_fault says why the last target_add failed (Target_Fault in
// api.odin), for a caller deciding whether to try the same drawable again.
// .None after one that succeeded.
target_fault :: proc "contextless" (r: ^Renderer) -> Target_Fault {
	return r.target_fault if r != nil else .None
}

// drawable_release lets go of a drawable the renderer never took — one a
// target_add refused. On Vulkan that destroys the VkSurfaceKHR, which is the
// renderer's job rather than the backend's because it must go before the
// window it was made from. A drawable a target does own is left alone, so
// calling this with one is safe: target_remove destroys that. Harmless with
// a zero drawable or before init.
drawable_release :: proc(r: ^Renderer, d: Drawable) {
	surface := vk.SurfaceKHR(d)
	if r == nil || r.inst == nil || surface == 0 do return
	for t in r.targets do if t.used && t.surface == surface do return
	vk.DestroySurfaceKHR(r.inst, surface, nil)
}

// target_resize records the new size and recreates the swapchain (with
// oldSwapchain handoff). A zero size destroys the swapchain so render returns
// .Skipped until a non-zero size arrives. Errors are logged; a lost surface
// makes the next render return .Lost.
target_resize :: proc(r: ^Renderer, t: Target, size_px: [2]u32) {
	ts := target_state(r, t)
	if ts == nil { return }
	ts.size_px = size_px
	if ts.lost { return }
	if swapchain_create(r, ts) == .Lost { ts.lost = true }
}

// target_remove waits for the target's frames, destroys its swapchain and
// the VkSurfaceKHR. The platform backend may destroy its native window
// afterwards (WSI teardown order: Vulkan surface before wl_surface / HWND).
target_remove :: proc(r: ^Renderer, t: Target) {
	ts := target_state(r, t)
	if ts == nil { return }
	if r.device != nil { vk.DeviceWaitIdle(r.device) }
	target_state_destroy(r, ts)
}

@(private)
choose_surface_format :: proc(r: ^Renderer, ts: ^Target_State) -> bool {
	count: u32
	if res := vk.GetPhysicalDeviceSurfaceFormatsKHR(r.phys, ts.surface, &count, nil); res != .SUCCESS || count == 0 {
		return fail(r, "vkGetPhysicalDeviceSurfaceFormatsKHR: %v (%d formats)", res, count)
	}
	formats := make([]vk.SurfaceFormatKHR, count, context.temp_allocator)
	vk.GetPhysicalDeviceSurfaceFormatsKHR(r.phys, ts.surface, &count, raw_data(formats))
	ts.format = pick_surface_format(formats, ts.transparent)
	return true
}

// pick_surface_format chooses a swapchain format. An opaque target takes
// B8G8R8A8_SRGB (else any sRGB format, else the first), so the hardware
// encodes on write. A transparent target takes B8G8R8A8_UNORM (else
// R8G8B8A8_UNORM, else as an opaque one), so its present pass writes the
// very values the compositor reads.
@(private)
pick_surface_format :: proc(formats: []vk.SurfaceFormatKHR, transparent: bool) -> vk.SurfaceFormatKHR {
	if len(formats) == 0 { return {} }
	if transparent {
		for want in ([]vk.Format{.B8G8R8A8_UNORM, .R8G8B8A8_UNORM}) {
			for f in formats {
				if f.format == want && f.colorSpace == .SRGB_NONLINEAR { return f }
			}
		}
	}
	for f in formats {
		if f.format == .B8G8R8A8_SRGB && f.colorSpace == .SRGB_NONLINEAR { return f }
	}
	for f in formats {
		#partial switch f.format {
		case .R8G8B8A8_SRGB, .A8B8G8R8_SRGB_PACK32, .B8G8R8_SRGB, .R8G8B8_SRGB:
			return f
		}
	}
	return formats[0]
}

// swapchain_create (re)creates ts's swapchain for ts.size_px. Existing
// per-image resources are destroyed after a device idle; the old swapchain
// is handed to oldSwapchain. .Zero = extent is empty, no swapchain exists.
@(private)
swapchain_create :: proc(r: ^Renderer, ts: ^Target_State) -> Swapchain_Result {
	caps: vk.SurfaceCapabilitiesKHR
	res := vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(r.phys, ts.surface, &caps)
	if res == .ERROR_SURFACE_LOST_KHR { return .Lost }
	if res != .SUCCESS {
		fail(r, "vkGetPhysicalDeviceSurfaceCapabilitiesKHR: %v", res)
		return .Error
	}

	// Wayland reports currentExtent = 0xFFFFFFFF (client decides); Win32 reports
	// the client rect (0×0 while minimised).
	extent: vk.Extent2D
	if caps.currentExtent.width != max(u32) {
		extent = caps.currentExtent
	} else if ts.size_px.x != 0 && ts.size_px.y != 0 {
		extent = {
			width  = clamp(ts.size_px.x, caps.minImageExtent.width,  caps.maxImageExtent.width),
			height = clamp(ts.size_px.y, caps.minImageExtent.height, caps.maxImageExtent.height),
		}
	}
	if extent.width == 0 || extent.height == 0 {
		swapchain_destroy(r, ts)
		return .Zero
	}

	image_count := caps.minImageCount
	if caps.maxImageCount != 0 { image_count = min(image_count, caps.maxImageCount) }

	composite := choose_composite_alpha(caps.supportedCompositeAlpha, ts.transparent)
	ts.present = present_mode_for(composite)
	usage: vk.ImageUsageFlags = {.COLOR_ATTACHMENT}
	ts.can_blit = .TRANSFER_SRC in caps.supportedUsageFlags
	if ts.can_blit { usage += {.TRANSFER_SRC} }

	old := ts.swapchain
	if old != 0 {
		vk.DeviceWaitIdle(r.device)
		swapchain_images_destroy(r, ts)
	}
	info := vk.SwapchainCreateInfoKHR{
		sType            = .SWAPCHAIN_CREATE_INFO_KHR,
		surface          = ts.surface,
		minImageCount    = image_count,
		imageFormat      = ts.format.format,
		imageColorSpace  = ts.format.colorSpace,
		imageExtent      = extent,
		imageArrayLayers = 1,
		imageUsage       = usage,
		imageSharingMode = .EXCLUSIVE,
		preTransform     = caps.currentTransform,
		compositeAlpha   = composite,
		presentMode      = .FIFO, // always supported; vsync-paced
		clipped          = true,
		oldSwapchain     = old,
	}
	res = vk.CreateSwapchainKHR(r.device, &info, nil, &ts.swapchain)
	if old != 0 {
		if ts.presents > 0 { // its picture may be the one on screen: kept until the new swapchain has shown one of its own (render)
			if ts.retired[1] != 0 { vk.DestroySwapchainKHR(r.device, ts.retired[1], nil) }
			ts.retired[1] = ts.retired[0]
			ts.retired[0] = old
		} else {
			vk.DestroySwapchainKHR(r.device, old, nil)
		}
	}
	ts.presents = 0
	if res != .SUCCESS {
		ts.swapchain = 0
		if res == .ERROR_SURFACE_LOST_KHR { return .Lost }
		fail(r, "vkCreateSwapchainKHR(%dx%d): %v", extent.width, extent.height, res)
		return .Error
	}
	ts.extent = extent

	count: u32
	vk.GetSwapchainImagesKHR(r.device, ts.swapchain, &count, nil)
	ts.images = make([]vk.Image, count)
	vk.GetSwapchainImagesKHR(r.device, ts.swapchain, &count, raw_data(ts.images))
	ts.views           = make([]vk.ImageView, count)
	ts.render_finished = make([]vk.Semaphore, count)
	ts.image_fence     = make([]vk.Fence, count)
	for img, i in ts.images {
		vi := vk.ImageViewCreateInfo{
			sType            = .IMAGE_VIEW_CREATE_INFO,
			image            = img,
			viewType         = .D2,
			format           = ts.format.format,
			subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
		}
		if res = vk.CreateImageView(r.device, &vi, nil, &ts.views[i]); res != .SUCCESS {
			fail(r, "vkCreateImageView: %v", res)
			swapchain_destroy(r, ts)
			return .Error
		}
		si := vk.SemaphoreCreateInfo{sType = .SEMAPHORE_CREATE_INFO}
		if res = vk.CreateSemaphore(r.device, &si, nil, &ts.render_finished[i]); res != .SUCCESS {
			fail(r, "vkCreateSemaphore: %v", res)
			swapchain_destroy(r, ts)
			return .Error
		}
	}
	return .OK
}

@(private)
choose_composite_alpha :: proc(supported: vk.CompositeAlphaFlagsKHR, transparent: bool) -> vk.CompositeAlphaFlagsKHR {
	order_transparent := [?]vk.CompositeAlphaFlagKHR{.PRE_MULTIPLIED, .INHERIT, .POST_MULTIPLIED, .OPAQUE}
	order_opaque      := [?]vk.CompositeAlphaFlagKHR{.OPAQUE, .INHERIT, .PRE_MULTIPLIED, .POST_MULTIPLIED}
	order := order_transparent[:] if transparent else order_opaque[:]
	for bit in order {
		if bit in supported { return {bit} }
	}
	return {.OPAQUE}
}

// swapchain_images_destroy frees per-image views/semaphores (device must be idle).
@(private)
swapchain_images_destroy :: proc(r: ^Renderer, ts: ^Target_State) {
	for v in ts.views           { if v != 0 { vk.DestroyImageView(r.device, v, nil) } }
	for s in ts.render_finished { if s != 0 { vk.DestroySemaphore(r.device, s, nil) } }
	delete(ts.views); delete(ts.render_finished); delete(ts.images); delete(ts.image_fence)
	ts.views = nil; ts.render_finished = nil; ts.images = nil; ts.image_fence = nil
}

@(private)
swapchain_destroy :: proc(r: ^Renderer, ts: ^Target_State) {
	if ts.swapchain == 0 && ts.images == nil && ts.retired == {} { return }
	vk.DeviceWaitIdle(r.device)
	blur_destroy(r, &ts.blur)
	sampled_image_destroy(r, &ts.scene)
	swapchain_images_destroy(r, ts)
	if ts.swapchain != 0 { vk.DestroySwapchainKHR(r.device, ts.swapchain, nil) }
	for old in ts.retired { if old != 0 { vk.DestroySwapchainKHR(r.device, old, nil) } }
	ts.swapchain, ts.retired, ts.presents = 0, {}, 0
	ts.extent = {}
}

// target_state_destroy releases everything a target owns, including the
// VkSurfaceKHR. Caller guarantees the device is idle.
@(private)
target_state_destroy :: proc(r: ^Renderer, ts: ^Target_State) {
	if r.device != nil {
		swapchain_destroy(r, ts)
		for &f in ts.frames {
			if f.image_available != 0 { vk.DestroySemaphore(r.device, f.image_available, nil) }
			if f.fence != 0 { vk.DestroyFence(r.device, f.fence, nil) }
			if f.cmd != nil { vk.FreeCommandBuffers(r.device, r.cmd_pool, 1, &f.cmd) }
			buffer_destroy(r, &f.vbuf)
			for &b in f.retire { buffer_destroy(r, &b) }
			delete(f.retire)
			for sem in f.sems { vk.DestroySemaphore(r.device, sem, nil) } // acquire fences nothing will wait on now
			delete(f.sems)
		}
	}
	if ts.surface != 0 && r.inst != nil { vk.DestroySurfaceKHR(r.inst, ts.surface, nil) }
	ts^ = {}
}
