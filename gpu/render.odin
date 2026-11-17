#+build !darwin
// render.odin — render(): turn a []Cmd into vertices + batches, record one
// command buffer (atlas uploads, clear, batched draws with per-batch scissor
// and atlas descriptor), submit, present (with VK_KHR_incremental_present
// damage when available), and handle swapchain recreation.
//
// Batching: consecutive commands sharing (atlas page, scissor) become one
// vkCmdDraw. Quads do not sample, so they join any page's batch; a batch
// that only has quads adopts the first glyph page that follows it.
package gpu

import "core:math"
import "core:mem"
import vk "vendor:vulkan"


// render records, submits and presents one frame of `cmds` on target `t`.
//
//   clear  linear RGBA written before the draws. Alpha is stored as given,
//          which matters for transparent targets ({0,0,0,0} = see-through;
//          pass premultiplied values for a tinted translucent backdrop,
//          premultiplied in linear light like the draws: the present pass
//          converts them for the compositor, present.odin).
//   damage device-px rects that changed since the last frame; empty = whole
//          surface. Forwarded to VK_KHR_incremental_present as a compositor
//          hint (the whole frame is always redrawn).
//
// Results: .OK — presented. .Skipped — the target has no swapchain (zero
// size) and nothing was drawn. .Recreated — the swapchain was out of date or
// suboptimal and has been recreated; the frame was drawn (call again for a
// fresh one if you want the new size on screen immediately). .Lost — the
// surface is gone; target_remove it. .Error — a Vulkan call failed
// (r.last_error says which). An empty `cmds` still clears and presents.
render :: proc(r: ^Renderer, t: Target, cmds: []Cmd, clear: [4]f32, damage: [][4]f32) -> Render_Result {
	ts := target_state(r, t)
	if ts == nil || r.device == nil { fail(r, "render: invalid target %d", t); return .Error }
	if r.lost { return .Lost } // the device has gone: nothing is drawn on it until recover.odin builds it again
	if ts.lost { return .Lost }
	if ts.swapchain == 0 {
		// No swapchain yet: try once (a resize may have come in via caps).
		switch swapchain_create(r, ts) {
		case .Zero:  return .Skipped
		case .Lost:  ts.lost = true; return .Lost
		case .Error: return .Error
		case .OK:
		}
	}

	slot := ts.slot
	frame := &ts.frames[slot]
	vk.WaitForFences(r.device, 1, &frame.fence, true, max(u64))
	for &b in frame.retire { staging_give(r, &b) }
	clear_dynamic_array(&frame.retire)
	dmabuf_frame_done(r, frame) // its acquire fences are spent: the semaphores serve again

	// ---- acquire (recreate on OUT_OF_DATE, at most twice)
	recreated := false
	recreate_after := false
	img: u32
	acquired := false
	for _ in 0 ..< 3 {
		acq := vk.AcquireNextImageKHR(r.device, ts.swapchain, max(u64), frame.image_available, 0, &img)
		if acq == .SUCCESS { acquired = true; break }
		if acq == .SUBOPTIMAL_KHR { acquired = true; recreate_after = true; break }
		if acq == .ERROR_OUT_OF_DATE_KHR {
			switch swapchain_create(r, ts) {
			case .Zero:  return .Skipped
			case .Lost:  ts.lost = true; return .Lost
			case .Error: return .Error
			case .OK:    recreated = true
			}
			continue
		}
		if acq == .ERROR_SURFACE_LOST_KHR { ts.lost = true; return .Lost }
		fail(r, "vkAcquireNextImageKHR: %v", acq)
		return .Error
	}
	if !acquired { fail(r, "vkAcquireNextImageKHR: still out of date after recreation"); return .Error }

	// The image may last have been drawn by the other slot whose work is
	// still in flight: wait for that slot's fence before reusing the image.
	if ts.image_fence[img] != 0 && ts.image_fence[img] != frame.fence {
		vk.WaitForFences(r.device, 1, &ts.image_fence[img], true, max(u64))
	}
	ts.image_fence[img] = frame.fence
	vk.ResetFences(r.device, 1, &frame.fence)
	if ts.transparent && !scene_ensure(r, ts) {
		recover_frame(r, ts, frame)
		return .Error
	}

	// ---- geometry
	build_batches(r, cmds, {ts.extent.width, ts.extent.height})
	if len(r.verts) > 0 {
		need := len(r.verts) * size_of(Vertex)
		if frame.vbuf.size < need {
			buffer_destroy(r, &frame.vbuf) // safe: this slot's fence was waited above
			cap := max(need + need / 2, 64 * 1024)
			vb, ok := buffer_create(r, cap, {.VERTEX_BUFFER}, true)
			if !ok { recover_frame(r, ts, frame); return .Error }
			frame.vbuf = vb
		}
		mem.copy(frame.vbuf.ptr, raw_data(r.verts), need)
	}

	// ---- record
	cb := frame.cmd
	vk.ResetCommandBuffer(cb, {})
	begin := vk.CommandBufferBeginInfo{sType = .COMMAND_BUFFER_BEGIN_INFO, flags = {.ONE_TIME_SUBMIT}}
	if res := vk.BeginCommandBuffer(cb, &begin); res != .SUCCESS {
		fail(r, "vkBeginCommandBuffer: %v", res)
		recover_frame(r, ts, frame)
		return .Error
	}
	record_uploads(r, cb, frame)
	r.submits += 1
	frame.serial = r.submits
	dmabuf_frame_begin(r, cb, t, slot, frame.serial) // the imported buffers this frame reads become ours

	// A transparent target draws into its scene; the present pass writes
	// that to the swapchain image (present.odin). The transition waits at
	// COLOR_ATTACHMENT_OUTPUT, the stage the acquire gates: at TOP_OF_PIPE it
	// could run on an image the window system still holds (a write-after-read
	// hazard against vkAcquireNextImageKHR).
	swapchain_barrier(cb, render_image(ts, img),
		{}, {.COLOR_ATTACHMENT_WRITE},
		.UNDEFINED, .COLOR_ATTACHMENT_OPTIMAL,
		{.COLOR_ATTACHMENT_OUTPUT}, {.COLOR_ATTACHMENT_OUTPUT})

	attach := vk.RenderingAttachmentInfo{
		sType       = .RENDERING_ATTACHMENT_INFO,
		imageView   = render_view(ts, img),
		imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
		loadOp      = .CLEAR,
		storeOp     = .STORE,
		clearValue  = {color = {float32 = clear}},
	}
	ri := vk.RenderingInfo{
		sType                = .RENDERING_INFO,
		renderArea           = {extent = ts.extent},
		layerCount           = 1,
		colorAttachmentCount = 1,
		pColorAttachments    = &attach,
	}
	if r.khr_dynamic_rendering { vk.CmdBeginRenderingKHR(cb, &ri) } else { vk.CmdBeginRendering(cb, &ri) }

	r.cur_blur_set = 0
	if len(r.verts) > 0 {
		bind_ui_state(r, ts, frame, cb)
		bound_set: vk.DescriptorSet
		for &b in r.batches {
			if b.kind == .Blur {
				// Blur what is on screen so far, then resume drawing on top.
				blur_pass(r, ts, cb, img, b.blur)
				bind_ui_state(r, ts, frame, cb)
				bound_set = 0
				continue
			}
			if b.count == 0 { continue }
			set := page_descriptor(r, b.page)
			if set != bound_set {
				vk.CmdBindDescriptorSets(cb, .GRAPHICS, r.pipeline_layout, 0, 1, &set, 0, nil)
				bound_set = set
			}
			// the one conversion point: Scissor is backend-neutral, this is not
			sc := vk.Rect2D{offset = {b.scissor.x, b.scissor.y}, extent = {b.scissor.w, b.scissor.h}}
			vk.CmdSetScissor(cb, 0, 1, &sc)
			vk.CmdDraw(cb, b.count, 1, b.first, 0)
		}
	}

	if r.khr_dynamic_rendering { vk.CmdEndRenderingKHR(cb) } else { vk.CmdEndRendering(cb) }
	dmabuf_frame_end(r, cb, t, slot, frame.serial) // …and go back, so the producer may write them again
	if ts.transparent { present_pass(r, ts, cb, img) }
	swapchain_barrier(cb, ts.images[img],
		{.COLOR_ATTACHMENT_WRITE}, {},
		.COLOR_ATTACHMENT_OPTIMAL, .PRESENT_SRC_KHR,
		{.COLOR_ATTACHMENT_OUTPUT}, {.BOTTOM_OF_PIPE})
	if res := vk.EndCommandBuffer(cb); res != .SUCCESS {
		fail(r, "vkEndCommandBuffer: %v", res)
		recover_frame(r, ts, frame)
		return .Error
	}

	// ---- submit + present
	// The swapchain image, and every acquire fence a producer handed over for
	// an imported buffer (dmabuf_*.odin): each is one signal, waited on once.
	waits := make([dynamic]vk.Semaphore, 0, 4, context.temp_allocator)
	stages := make([dynamic]vk.PipelineStageFlags, 0, 4, context.temp_allocator)
	append(&waits, frame.image_available)
	append(&stages, vk.PipelineStageFlags{.COLOR_ATTACHMENT_OUTPUT})
	for sem in dmabuf_waits(r, frame) {
		append(&waits, sem)
		append(&stages, vk.PipelineStageFlags{.FRAGMENT_SHADER})
	}
	submit := vk.SubmitInfo{
		sType                = .SUBMIT_INFO,
		waitSemaphoreCount   = u32(len(waits)),
		pWaitSemaphores      = raw_data(waits),
		pWaitDstStageMask    = raw_data(stages),
		commandBufferCount   = 1,
		pCommandBuffers      = &cb,
		signalSemaphoreCount = 1,
		pSignalSemaphores    = &ts.render_finished[img],
	}
	if res := vk.QueueSubmit(r.queue, 1, &submit, frame.fence); res != .SUCCESS {
		fail(r, "vkQueueSubmit: %v", res)
		if res == .ERROR_DEVICE_LOST { ts.lost = true; mark_lost(r); return .Lost }
		recover_frame(r, ts, frame)
		return .Error
	}
	ts.slot = (slot + 1) % FRAMES_IN_FLIGHT

	present := vk.PresentInfoKHR{
		sType              = .PRESENT_INFO_KHR,
		waitSemaphoreCount = 1,
		pWaitSemaphores    = &ts.render_finished[img],
		swapchainCount     = 1,
		pSwapchains        = &ts.swapchain,
		pImageIndices      = &img,
	}
	region:  vk.PresentRegionKHR
	regions: vk.PresentRegionsKHR
	if r.has_incremental_present && len(damage) > 0 {
		clear_dynamic_array(&r.rects)
		for d in damage {
			x0 := clamp(i32(math.floor(d.x)), 0, i32(ts.extent.width))
			y0 := clamp(i32(math.floor(d.y)), 0, i32(ts.extent.height))
			x1 := clamp(i32(math.ceil(d.x + d.z)), 0, i32(ts.extent.width))
			y1 := clamp(i32(math.ceil(d.y + d.w)), 0, i32(ts.extent.height))
			if x1 > x0 && y1 > y0 {
				append(&r.rects, vk.RectLayerKHR{offset = {x0, y0}, extent = {u32(x1 - x0), u32(y1 - y0)}, layer = 0})
			}
		}
		if len(r.rects) > 0 {
			region  = {rectangleCount = u32(len(r.rects)), pRectangles = raw_data(r.rects)}
			regions = {sType = .PRESENT_REGIONS_KHR, swapchainCount = 1, pRegions = &region}
			present.pNext = &regions
		}
	}
	pres := vk.QueuePresentKHR(r.queue, &present)
	#partial switch pres {
	case .SUCCESS:
		r.frames += 1
	case .SUBOPTIMAL_KHR, .ERROR_OUT_OF_DATE_KHR:
		if pres == .SUBOPTIMAL_KHR { r.frames += 1 }
		recreate_after = true
	case .ERROR_SURFACE_LOST_KHR:
		ts.lost = true
		return .Lost
	case .ERROR_DEVICE_LOST:
		fail(r, "vkQueuePresentKHR: %v", pres)
		mark_lost(r)
		return .Lost
	case:
		fail(r, "vkQueuePresentKHR: %v", pres)
		return .Error
	}
	if pres == .SUCCESS || pres == .SUBOPTIMAL_KHR {
		ts.presents += 1
		// A compositor with explicit sync shows a new buffer only once its acquire point signals,
		// and destroying the swapchain before then takes the picture on screen with it. By the
		// new swapchain's second present its first has been shown: the ones it replaced can go.
		if ts.presents >= 2 {
			for &old in ts.retired {
				if old != 0 { vk.DestroySwapchainKHR(r.device, old, nil); old = 0 }
			}
		}
	}

	if recreate_after {
		switch swapchain_create(r, ts) {
		case .OK, .Zero: recreated = true
		case .Lost:      ts.lost = true; return .Lost
		case .Error:     return .Error
		}
	}
	return .Recreated if recreated else .OK
}

// recover_frame puts a slot back into a usable state after a failure between
// acquire and submit: its fence was reset but will never signal and its
// acquire semaphore is signaled with no consumer, either of which would hang
// or invalidate the next render on this slot. Waits for the device, then
// replaces both objects (fence created signaled) and forgets the per-image
// fence table (everything is idle now).
@(private)
recover_frame :: proc(r: ^Renderer, ts: ^Target_State, frame: ^Frame) {
	vk.DeviceWaitIdle(r.device)
	vk.DestroySemaphore(r.device, frame.image_available, nil)
	vk.DestroyFence(r.device, frame.fence, nil)
	si := vk.SemaphoreCreateInfo{sType = .SEMAPHORE_CREATE_INFO}
	fi := vk.FenceCreateInfo{sType = .FENCE_CREATE_INFO, flags = {.SIGNALED}}
	vk.CreateSemaphore(r.device, &si, nil, &frame.image_available)
	vk.CreateFence(r.device, &fi, nil, &frame.fence)
	for &f in ts.image_fence { f = 0 }
}

// bind_ui_state (re)binds everything the UI pipeline needs inside a dynamic
// rendering scope: viewport, pipeline, vertex buffer, push constants.
@(private)
bind_ui_state :: proc(r: ^Renderer, ts: ^Target_State, frame: ^Frame, cb: vk.CommandBuffer) {
	vp := vk.Viewport{width = f32(ts.extent.width), height = f32(ts.extent.height), minDepth = 0, maxDepth = 1}
	vk.CmdSetViewport(cb, 0, 1, &vp)
	vk.CmdBindPipeline(cb, .GRAPHICS, ts.pipeline)
	offset: vk.DeviceSize = 0
	vk.CmdBindVertexBuffers(cb, 0, 1, &frame.vbuf.buf, &offset)
	pc := Push_Constants{viewport = {f32(ts.extent.width), f32(ts.extent.height)}}
	vk.CmdPushConstants(cb, r.pipeline_layout, {.VERTEX}, 0, size_of(pc), &pc)
}

// page_descriptor resolves a Page to its descriptor set; 0/invalid → WHITE_PAGE.
@(private)
page_descriptor :: proc(r: ^Renderer, p: Page) -> vk.DescriptorSet {
	if p == BLUR_PAGE && r.cur_blur_set != 0 { return r.cur_blur_set }
	if ps := page_state(r, p); ps != nil { return ps.set }
	return r.pages[int(WHITE_PAGE) - 1].set
}

// ------------------------------------------------------------- barriers

@(private)
swapchain_barrier :: proc(
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
