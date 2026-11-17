#+build !darwin
// canvas.odin — canvases: textures an app draws into and shows, in the bit
// depths an image editor works in, each with the colour space its values
// are in.
//
// A canvas is a page (so an Image command draws it) whose texels are
// sampled as they are stored, never decoded by the format: the fragment
// shader decodes the canvas's colour space to linear sRGB, the display
// transform (sRGB; there is no wide-gamut target yet). Work on canvases —
// clearing a new one, writing pixels, filling a rectangle, copying between
// them, reading back — is queued in the order it is asked for and recorded
// by canvas_flush into a command buffer of its own, submitted on the queue
// the frames use. A frame drawn after it therefore sees it, and a flush
// needs no frame: work on a canvas nobody shows still runs, and a read of
// it still finishes. Reads come back through the batch's fence:
// canvas_wait blocks until it has signalled (any thread), canvas_reads_take
// then hands the bytes over (the renderer's thread).
//
// Values are straight alpha. RGBA8 and RGBA16 are UNORM (0..1, the space's
// encoded values); RGBA32F takes any float. A canvas's smaller mip levels,
// for drawing it reduced, are rebuilt by linear blits after the work that
// touched it, averaging stored values.
package gpu

import "core:mem"
import vk "vendor:vulkan"

// Canvas_Wait is what canvas_wait needs to block on a batch from another
// thread; its fields are the renderer's.
Canvas_Wait :: struct {
	device: vk.Device,
	fence:  vk.Fence,
}

// Transform_Push is transform.frag's push constant. A mat3 in a push block
// is three vec4-aligned columns, which is why `inv` is [3][4]f32 and not
// [9]f32: get that wrong and the matrix arrives sheared.
@(private)
Transform_Push :: struct {
	inv:      [3][4]f32,
	back_off: [2]i32,
	mask_off: [2]i32,
	src_rect: [4]i32,
	mode:     u32,
	flags:    u32,
	kernel:   u32,
	opacity:  f32,
}
#assert(size_of(Transform_Push) == 96)

TRANSFORM_FRAG_SPV := #load("shaders/transform.frag.spv", []u32)


// canvas_transform_pipeline is the transform pass drawing into canvases of
// `format`, made once per format.
@(private)
canvas_transform_pipeline :: proc(r: ^Renderer, format: Canvas_Format) -> vk.Pipeline {
	if r.transform_pipelines[format] != 0 do return r.transform_pipelines[format]
	if r.transform_layout == 0 {
		push := vk.PushConstantRange{stageFlags = {.FRAGMENT}, offset = 0, size = size_of(Transform_Push)}
		sets := [3]vk.DescriptorSetLayout{r.desc_layout, r.desc_layout, r.desc_layout}
		pl := vk.PipelineLayoutCreateInfo{sType = .PIPELINE_LAYOUT_CREATE_INFO, setLayoutCount = 3, pSetLayouts = &sets[0], pushConstantRangeCount = 1, pPushConstantRanges = &push}
		if res := vk.CreatePipelineLayout(r.device, &pl, nil, &r.transform_layout); res != .SUCCESS {
			fail(r, "canvas transform: vkCreatePipelineLayout: %v", res)
			return 0
		}
	}
	p, ok := fullscreen_pipeline_create(r, TRANSFORM_FRAG_SPV, r.transform_layout, canvas_vk_format(format))
	if ok do r.transform_pipelines[format] = p
	return p
}

// Blend_Push is blend.frag's push constant.
@(private)
Blend_Push :: struct {
	src_off, back_off, mask_off: [2]i32,
	mode, flags:                 u32,
	opacity:                     f32,
	seed:                        u32,
	_:                           [2]u32,
	color:                       [4]f32,
}
#assert(size_of(Blend_Push) == 64)

BLEND_FRAG_SPV := #load("shaders/blend.frag.spv", []u32)

@(private)
Canvas_Batch :: struct {
	id:      u64,
	cmd:     vk.CommandBuffer,
	fence:   vk.Fence,
	staging: [dynamic]Buffer,
	reads:   [dynamic]Canvas_Pending_Read,
}

@(private)
Canvas_Pending_Read :: struct {
	id:   u32,
	buf:  Buffer,
	size: int,
}

// canvas_buffer is what canvas_queue.odin asks for when it needs a buffer
// the CPU writes and the GPU reads: Vulkan wants the usage declared, Metal
// does not, so the shared code names the purpose and each backend maps it.
@(private)
canvas_buffer :: proc(r: ^Renderer, size: int, use: Buffer_Use) -> (Buffer, bool) {
	usage: vk.BufferUsageFlags
	switch use {
	case .Upload: usage = {.TRANSFER_SRC}
	case .Vertex: usage = {.VERTEX_BUFFER}
	case .Read:   usage = {.TRANSFER_DST}
	}
	b, ok := buffer_create(r, size, usage, true)
	b.use = use
	return b, ok
}

@(private)
canvas_vk_format :: proc "contextless" (f: Canvas_Format) -> vk.Format {
	switch f {
	case .RGBA8:   return .R8G8B8A8_UNORM
	case .RGBA16:  return .R16G16B16A16_UNORM
	case .RGBA32F: return .R32G32B32A32_SFLOAT
	case .R8:      return .R8_UNORM
	case .R16:     return .R16_UNORM
	}
	return .R8G8B8A8_UNORM
}


// canvas_formats_probe notes what the device can do with each canvas
// format (device creation).
@(private)
canvas_formats_probe :: proc(r: ^Renderer) {
	props: vk.PhysicalDeviceMemoryProperties
	vk.GetPhysicalDeviceMemoryProperties(r.phys, &props)
	for i in 0 ..< props.memoryHeapCount do if .DEVICE_LOCAL in props.memoryHeaps[i].flags do r.canvas_memory = max(r.canvas_memory, u64(props.memoryHeaps[i].size))
	for f in Canvas_Format {
		fp: vk.FormatProperties
		vk.GetPhysicalDeviceFormatProperties(r.phys, canvas_vk_format(f), &fp)
		have := fp.optimalTilingFeatures
		if (vk.FormatFeatureFlags{.SAMPLED_IMAGE, .TRANSFER_SRC, .TRANSFER_DST, .COLOR_ATTACHMENT, .BLIT_SRC, .BLIT_DST}) <= have {
			r.canvas_formats += {f}
			if .SAMPLED_IMAGE_FILTER_LINEAR in have do r.canvas_filtered += {f}
			if .STORAGE_IMAGE in have do r.canvas_storage += {f}
		}
	}
}

// limits says what canvases the device can have; zero before the device
// exists (the first target_add).
limits :: proc(r: ^Renderer) -> Limits {
	if r.device == nil do return {}
	return {max_side = r.max_image_dim, device_memory = r.canvas_memory, formats = r.canvas_formats, filtered = r.canvas_filtered, storage = r.canvas_storage}
}

// canvas_create makes a `size` canvas of `format` in `space`, cleared to
// transparent by the next canvas_flush. 0 when there is no device yet, the
// device cannot make canvases of `format`, a side is 0 or past the device's
// limit, or the memory cannot be had.
canvas_create :: proc(r: ^Renderer, size: [2]u32, format: Canvas_Format, space: Color_Space, mips := true) -> Page {
	return canvas_make(r, size, format, space, clear = true, mips = mips)
}

@(private)
canvas_make :: proc(r: ^Renderer, size: [2]u32, format: Canvas_Format, space: Color_Space, clear: bool, mips := true) -> Page {
	if r.device == nil || format not_in r.canvas_formats do return 0
	if size.x == 0 || size.y == 0 || size.x > r.max_image_dim || size.y > r.max_image_dim do return 0
	filtered := format in r.canvas_filtered
	levels: u32 = 1
	// A canvas nobody shows scaled down has no use for a mip chain: it is a
	// third more memory and a rebuild over the touched rect after every batch.
	if filtered && mips do for m := max(size.x, size.y); m > 1; m >>= 1 do levels += 1
	slot := -1
	for &p, i in r.pages do if !p.used {
		slot = i
		break
	}
	if slot < 0 {
		append(&r.pages, Page_State{})
		slot = len(r.pages) - 1
	}
	ps := &r.pages[slot]
	ps^ = {used = true, format = .RGBA8, size = size, levels = levels, canvas = true, canvas_format = format, space = space, initialized = true}
	info := vk.ImageCreateInfo{
		sType         = .IMAGE_CREATE_INFO,
		imageType     = .D2,
		format        = canvas_vk_format(format),
		extent        = {size.x, size.y, 1},
		mipLevels     = levels,
		arrayLayers   = 1,
		samples       = {._1},
		tiling        = .OPTIMAL,
		usage         = {.SAMPLED, .TRANSFER_SRC, .TRANSFER_DST, .COLOR_ATTACHMENT} + ({.STORAGE} if format in r.canvas_storage else {}),
		sharingMode   = .EXCLUSIVE,
		initialLayout = .UNDEFINED,
	}
	ps.storage = format in r.canvas_storage
	if res := vk.CreateImage(r.device, &info, nil, &ps.image); res != .SUCCESS {
		fail(r, "canvas_create: vkCreateImage(%dx%d %v): %v", size.x, size.y, format, res)
		ps^ = {}
		return 0
	}
	req: vk.MemoryRequirements
	vk.GetImageMemoryRequirements(r.device, ps.image, &req)
	type_index, found := find_memory_type(r, req.memoryTypeBits, {.DEVICE_LOCAL})
	if !found do type_index, found = find_memory_type(r, req.memoryTypeBits, {})
	alloc := vk.MemoryAllocateInfo{sType = .MEMORY_ALLOCATE_INFO, allocationSize = req.size, memoryTypeIndex = type_index}
	if !found || vk.AllocateMemory(r.device, &alloc, nil, &ps.memory) != .SUCCESS || vk.BindImageMemory(r.device, ps.image, ps.memory, 0) != .SUCCESS {
		fail(r, "canvas_create: no memory for %dx%d %v", size.x, size.y, format)
		page_state_destroy(r, ps)
		return 0
	}
	views := [2]u32{levels, 1} // sampled: every level; drawn into: level 0
	for n, i in views {
		vi := vk.ImageViewCreateInfo{
			sType            = .IMAGE_VIEW_CREATE_INFO,
			image            = ps.image,
			viewType         = .D2,
			format           = info.format,
			subresourceRange = {aspectMask = {.COLOR}, levelCount = n, layerCount = 1},
		}
		out := &ps.view if i == 0 else &ps.target_view
		if vk.CreateImageView(r.device, &vi, nil, out) != .SUCCESS {
			fail(r, "canvas_create: vkCreateImageView")
			page_state_destroy(r, ps)
			return 0
		}
	}
	set, pool, ok := desc_set_alloc(r)
	if !ok {
		page_state_destroy(r, ps)
		return 0
	}
	ps.set, ps.pool = set, pool
	sampler := r.nearest_sampler
	if filtered do sampler = r.mip_sampler if levels > 1 else r.sampler
	img_info := vk.DescriptorImageInfo{sampler = sampler, imageView = ps.view, imageLayout = .SHADER_READ_ONLY_OPTIMAL}
	write := vk.WriteDescriptorSet{sType = .WRITE_DESCRIPTOR_SET, dstSet = ps.set, dstBinding = 0, descriptorCount = 1, descriptorType = .COMBINED_IMAGE_SAMPLER, pImageInfo = &img_info}
	vk.UpdateDescriptorSets(r.device, 1, &write, 0, nil)
	page := Page(slot + 1)
	ps.layout = .UNDEFINED
	if clear do append(&r.canvas_ops, Canvas_Op{kind = .Clear, page = page, w = size.x, h = size.y})
	return page
}


















// canvas_flush records the queued work into a command buffer of its own
// and submits it; `batch` names it (0: nothing to do, or it failed, which
// r.last_error says) and `reads` says whether it carries reads, which
// canvas_wait and canvas_reads_take then finish. A canvas whose texels
// changed has its smaller levels rebuilt. Call it on the renderer's thread,
// before rendering the frames that show the work.
canvas_flush :: proc(r: ^Renderer) -> (batch: u64, reads: bool) {
	canvas_retire(r)
	staging_age(r)
	writing_closed(r)
	if len(r.canvas_ops) == 0 || r.device == nil do return
	// the blends' backdrop copies, big enough for the whole batch before any
	// command names one (growing one means making it again)
	need: [2][Canvas_Format][2]u32
	grow :: proc(n: ^[2]u32, w, h: u32) { n^ = {max(n.x, w), max(n.y, h)} }
	for op in r.canvas_ops {
		#partial switch op.kind {
		case .Blend:
			if d := canvas_page(r, op.page); d != nil do grow(&need[0][d.canvas_format], op.w, op.h)
		case .Shader:
			st := shader_state(r, op.shader)
			if d := canvas_page(r, op.page); d != nil && st != nil && st.backdrop do grow(&need[0][d.canvas_format], op.w, op.h)
		case .Filter:
			sp := canvas_page(r, op.src)
			if sp == nil do continue
			x0, y0, x1, y1 := filter_region(sp, op)
			grow(&need[0][sp.canvas_format], x1 - x0, y1 - y0)
			if op.filter.kind == .Blur || op.filter.kind == .Sharpen do grow(&need[1][.RGBA32F], op.w, y1 - y0)
		}
	}
	for slot in 0 ..< 2 do for size, f in need[slot] do if size.x > 0 do canvas_scratch(r, f, size, slot)
	b := new(Canvas_Batch)
	alloc := vk.CommandBufferAllocateInfo{sType = .COMMAND_BUFFER_ALLOCATE_INFO, commandPool = r.cmd_pool, level = .PRIMARY, commandBufferCount = 1}
	fence_info := vk.FenceCreateInfo{sType = .FENCE_CREATE_INFO}
	if vk.AllocateCommandBuffers(r.device, &alloc, &b.cmd) != .SUCCESS || vk.CreateFence(r.device, &fence_info, nil, &b.fence) != .SUCCESS {
		fail(r, "canvas_flush: no command buffer or fence")
		canvas_batch_free(r, b)
		canvas_ops_drop(r)
		return
	}
	cb := b.cmd
	begin := vk.CommandBufferBeginInfo{sType = .COMMAND_BUFFER_BEGIN_INFO, flags = {.ONE_TIME_SUBMIT}}
	vk.BeginCommandBuffer(cb, &begin)
	touched := make(map[Page][4]u32, context.temp_allocator) // what changed on each, for its levels
	used := make(map[Page]bool, context.temp_allocator)      // every canvas the batch left out of SHADER_READ_ONLY
	// The scratch each format shares is sized for the whole batch *before*
	// any command is recorded: growing it mid-batch would destroy an image an
	// earlier op has already recorded a descriptor for, and the GPU would
	// read freed memory.
	{
		want: [Canvas_Format][2]u32
		for &op in r.canvas_ops {
			if op.kind != .Blend && op.kind != .Transform do continue
			ps := canvas_page(r, op.page)
			if ps == nil do continue
			w := &want[ps.canvas_format]
			w^ = {max(w[0], op.w), max(w[1], op.h)}
		}
		for size, f in want do if size[0] > 0 do canvas_scratch(r, f, size)
	}
	to :: proc(cb: vk.CommandBuffer, ps: ^Page_State, layout: vk.ImageLayout) {
		if ps.layout == layout do return
		page_barrier(cb, ps.image, ps.layout, layout, 0, ps.levels)
		ps.layout = layout
	}
	touch :: proc(touched: ^map[Page][4]u32, p: Page, x, y, w, h: u32) {
		t, had := touched[p]
		touched[p] = {min(t[0], x), min(t[1], y), max(t[2], x + w), max(t[3], y + h)} if had else {x, y, x + w, y + h}
	}
	for &op in r.canvas_ops {
		ps := canvas_page(r, op.page)
		if ps == nil {
			if op.kind == .Write || op.kind == .Dabs || (op.kind == .Strokes && op.own) do append(&b.staging, op.staging)
			continue
		}
		used[op.page] = true
		switch op.kind {
		case .Clear:
			to(cb, ps, .TRANSFER_DST_OPTIMAL)
			zero: vk.ClearColorValue
			all := vk.ImageSubresourceRange{aspectMask = {.COLOR}, levelCount = ps.levels, layerCount = 1}
			vk.CmdClearColorImage(cb, ps.image, .TRANSFER_DST_OPTIMAL, &zero, 1, &all)
			touch(&touched, op.page, 0, 0, ps.size.x, ps.size.y)
		case .Write:
			to(cb, ps, .TRANSFER_DST_OPTIMAL)
			region := vk.BufferImageCopy{imageSubresource = {aspectMask = {.COLOR}, layerCount = 1}, imageOffset = {i32(op.x), i32(op.y), 0}, imageExtent = {op.w, op.h, 1}}
			vk.CmdCopyBufferToImage(cb, op.staging.buf, ps.image, .TRANSFER_DST_OPTIMAL, 1, &region)
			append(&b.staging, op.staging)
			touch(&touched, op.page, op.x, op.y, op.w, op.h)
		case .Fill:
			to(cb, ps, .COLOR_ATTACHMENT_OPTIMAL)
			rect := vk.Rect2D{offset = {i32(op.x), i32(op.y)}, extent = {op.w, op.h}}
			attach := vk.RenderingAttachmentInfo{sType = .RENDERING_ATTACHMENT_INFO, imageView = ps.target_view, imageLayout = .COLOR_ATTACHMENT_OPTIMAL, loadOp = .LOAD, storeOp = .STORE}
			ri := vk.RenderingInfo{sType = .RENDERING_INFO, renderArea = rect, layerCount = 1, colorAttachmentCount = 1, pColorAttachments = &attach}
			if r.khr_dynamic_rendering { vk.CmdBeginRenderingKHR(cb, &ri) } else { vk.CmdBeginRendering(cb, &ri) }
			clear := vk.ClearAttachment{aspectMask = {.COLOR}, colorAttachment = 0}
			clear.clearValue.color.float32 = op.value
			area := vk.ClearRect{rect = rect, layerCount = 1}
			vk.CmdClearAttachments(cb, 1, &clear, 1, &area)
			if r.khr_dynamic_rendering { vk.CmdEndRenderingKHR(cb) } else { vk.CmdEndRendering(cb) }
			touch(&touched, op.page, op.x, op.y, op.w, op.h)
		case .Copy:
			src := canvas_page(r, op.src)
			if src == nil do continue
			used[op.src] = true
			if src == ps {
				to(cb, ps, .GENERAL) // one image, two regions: both ends in one layout
			} else {
				to(cb, src, .TRANSFER_SRC_OPTIMAL)
				to(cb, ps, .TRANSFER_DST_OPTIMAL)
			}
			if src.canvas_format == ps.canvas_format {
				region := vk.ImageCopy{
					srcSubresource = {aspectMask = {.COLOR}, layerCount = 1}, srcOffset = {i32(op.sx), i32(op.sy), 0},
					dstSubresource = {aspectMask = {.COLOR}, layerCount = 1}, dstOffset = {i32(op.x), i32(op.y), 0},
					extent = {op.w, op.h, 1},
				}
				vk.CmdCopyImage(cb, src.image, src.layout, ps.image, ps.layout, 1, &region)
			} else { // another format: a blit, one texel to one, converts the values
				blit := vk.ImageBlit{
					srcSubresource = {aspectMask = {.COLOR}, layerCount = 1},
					srcOffsets     = {{i32(op.sx), i32(op.sy), 0}, {i32(op.sx + op.w), i32(op.sy + op.h), 1}},
					dstSubresource = {aspectMask = {.COLOR}, layerCount = 1},
					dstOffsets     = {{i32(op.x), i32(op.y), 0}, {i32(op.x + op.w), i32(op.y + op.h), 1}},
				}
				vk.CmdBlitImage(cb, src.image, src.layout, ps.image, ps.layout, 1, &blit, .NEAREST)
			}
			touch(&touched, op.page, op.x, op.y, op.w, op.h)
		case .Transform:
			src := canvas_page(r, op.src)
			if src == nil do continue
			mask := canvas_page(r, op.mask) if op.mask != 0 else nil
			scratch := canvas_scratch(r, ps.canvas_format, {op.w, op.h})
			pipeline := canvas_transform_pipeline(r, ps.canvas_format)
			if scratch == nil || pipeline == 0 do continue
			used[op.src] = true
			if mask != nil do used[op.mask] = true
			used[r.canvas_scratch[0][ps.canvas_format]] = true
			// the backdrop, as the blend pass takes it: what is under the
			// rectangle now, so the shader can lay the source over it
			to(cb, ps, .TRANSFER_SRC_OPTIMAL)
			to(cb, scratch, .TRANSFER_DST_OPTIMAL)
			region := vk.ImageCopy{
				srcSubresource = {aspectMask = {.COLOR}, layerCount = 1}, srcOffset = {i32(op.x), i32(op.y), 0},
				dstSubresource = {aspectMask = {.COLOR}, layerCount = 1}, extent = {op.w, op.h, 1},
			}
			vk.CmdCopyImage(cb, ps.image, .TRANSFER_SRC_OPTIMAL, scratch.image, .TRANSFER_DST_OPTIMAL, 1, &region)
			to(cb, scratch, .SHADER_READ_ONLY_OPTIMAL)
			to(cb, src, .SHADER_READ_ONLY_OPTIMAL)
			if mask != nil do to(cb, mask, .SHADER_READ_ONLY_OPTIMAL)
			to(cb, ps, .COLOR_ATTACHMENT_OPTIMAL)
			rect := vk.Rect2D{offset = {i32(op.x), i32(op.y)}, extent = {op.w, op.h}}
			attach := vk.RenderingAttachmentInfo{sType = .RENDERING_ATTACHMENT_INFO, imageView = ps.target_view, imageLayout = .COLOR_ATTACHMENT_OPTIMAL, loadOp = .LOAD, storeOp = .STORE}
			ri := vk.RenderingInfo{sType = .RENDERING_INFO, renderArea = rect, layerCount = 1, colorAttachmentCount = 1, pColorAttachments = &attach}
			if r.khr_dynamic_rendering { vk.CmdBeginRenderingKHR(cb, &ri) } else { vk.CmdBeginRendering(cb, &ri) }
			vk.CmdBindPipeline(cb, .GRAPHICS, pipeline)
			vp := vk.Viewport{width = f32(ps.size.x), height = f32(ps.size.y), maxDepth = 1}
			vk.CmdSetViewport(cb, 0, 1, &vp)
			vk.CmdSetScissor(cb, 0, 1, &rect)
			white := page_state(r, WHITE_PAGE)
			sets := [3]vk.DescriptorSet{src.set, scratch.set, mask.set if mask != nil else white.set}
			vk.CmdBindDescriptorSets(cb, .GRAPHICS, r.transform_layout, 0, 3, &sets[0], 0, nil)
			flags := u32(1 if op.linear else 0) | u32(2 if mask != nil else 0) | canvas_curve(ps.space) << 2 | canvas_curve(src.space) << 4
			push := Transform_Push{
				back_off = {-i32(op.x), -i32(op.y)},
				mask_off = {-i32(op.x), -i32(op.y)},
				src_rect = {i32(op.sx), i32(op.sy), i32(op.sw), i32(op.sh)},
				mode = u32(op.mode), flags = flags, kernel = op.kernel, opacity = op.opacity,
			}
			for c in 0 ..< 3 do for row in 0 ..< 3 do push.inv[c][row] = op.inv[c * 3 + row]
			vk.CmdPushConstants(cb, r.transform_layout, {.FRAGMENT}, 0, size_of(Transform_Push), &push)
			vk.CmdDraw(cb, 3, 1, 0, 0)
			if r.khr_dynamic_rendering { vk.CmdEndRenderingKHR(cb) } else { vk.CmdEndRendering(cb) }
			touch(&touched, op.page, op.x, op.y, op.w, op.h)
		case .Blend:
			src := canvas_page(r, op.src) if !op.solid else ps // a colour: nothing to sample (bound, never read)
			if src == nil do continue
			mask := canvas_page(r, op.mask) if op.mask != 0 else nil
			scratch := canvas_scratch(r, ps.canvas_format, {op.w, op.h})
			pipeline := canvas_blend_pipeline(r, ps.canvas_format)
			if scratch == nil || pipeline == 0 do continue
			if !op.solid do used[op.src] = true
			if mask != nil do used[op.mask] = true
			used[r.canvas_scratch[0][ps.canvas_format]] = true
			// the backdrop: what is under the rectangle now, into the scratch
			to(cb, ps, .TRANSFER_SRC_OPTIMAL)
			to(cb, scratch, .TRANSFER_DST_OPTIMAL)
			region := vk.ImageCopy{
				srcSubresource = {aspectMask = {.COLOR}, layerCount = 1}, srcOffset = {i32(op.x), i32(op.y), 0},
				dstSubresource = {aspectMask = {.COLOR}, layerCount = 1}, extent = {op.w, op.h, 1},
			}
			vk.CmdCopyImage(cb, ps.image, .TRANSFER_SRC_OPTIMAL, scratch.image, .TRANSFER_DST_OPTIMAL, 1, &region)
			to(cb, scratch, .SHADER_READ_ONLY_OPTIMAL)
			if !op.solid do to(cb, src, .SHADER_READ_ONLY_OPTIMAL)
			if mask != nil do to(cb, mask, .SHADER_READ_ONLY_OPTIMAL)
			to(cb, ps, .COLOR_ATTACHMENT_OPTIMAL)
			rect := vk.Rect2D{offset = {i32(op.x), i32(op.y)}, extent = {op.w, op.h}}
			attach := vk.RenderingAttachmentInfo{sType = .RENDERING_ATTACHMENT_INFO, imageView = ps.target_view, imageLayout = .COLOR_ATTACHMENT_OPTIMAL, loadOp = .LOAD, storeOp = .STORE}
			ri := vk.RenderingInfo{sType = .RENDERING_INFO, renderArea = rect, layerCount = 1, colorAttachmentCount = 1, pColorAttachments = &attach}
			if r.khr_dynamic_rendering { vk.CmdBeginRenderingKHR(cb, &ri) } else { vk.CmdBeginRendering(cb, &ri) }
			vk.CmdBindPipeline(cb, .GRAPHICS, pipeline)
			vp := vk.Viewport{width = f32(ps.size.x), height = f32(ps.size.y), maxDepth = 1}
			vk.CmdSetViewport(cb, 0, 1, &vp)
			vk.CmdSetScissor(cb, 0, 1, &rect)
			white := page_state(r, WHITE_PAGE)
			sets := [3]vk.DescriptorSet{white.set if op.solid else src.set, scratch.set, mask.set if mask != nil else white.set}
			vk.CmdBindDescriptorSets(cb, .GRAPHICS, r.blend_layout, 0, 3, &sets[0], 0, nil)
			flags := u32(1 if op.linear else 0) | u32(2 if mask != nil else 0) | canvas_curve(ps.space) << 2 | canvas_curve(src.space) << 4
			if op.solid do flags |= 64
			if op.erase do flags |= 128
			push := Blend_Push{
				src_off  = {i32(op.sx) - i32(op.x), i32(op.sy) - i32(op.y)},
				back_off = {-i32(op.x), -i32(op.y)},
				mask_off = {i32(op.sx) - i32(op.x), i32(op.sy) - i32(op.y)},
				mode = u32(op.mode), flags = flags, opacity = op.opacity, seed = op.seed, color = op.value,
			}
			vk.CmdPushConstants(cb, r.blend_layout, {.FRAGMENT}, 0, size_of(Blend_Push), &push)
			vk.CmdDraw(cb, 3, 1, 0, 0)
			if r.khr_dynamic_rendering { vk.CmdEndRenderingKHR(cb) } else { vk.CmdEndRendering(cb) }
			touch(&touched, op.page, op.x, op.y, op.w, op.h)
		case .Filter:
			src := canvas_page(r, op.src)
			if src == nil do continue
			f := op.filter
			x0, y0, x1, y1 := filter_region(src, op)
			copy_ := canvas_scratch(r, src.canvas_format, {x1 - x0, y1 - y0})
			pipe := canvas_filter_pipeline(r, ps.canvas_format)
			if copy_ == nil || pipe == 0 do continue
			used[op.src] = true
			used[r.canvas_scratch[0][src.canvas_format]] = true
			// the input: the source's rectangle and margin, copied, so a filter may write onto its own canvas
			to(cb, src, .TRANSFER_SRC_OPTIMAL)
			to(cb, copy_, .TRANSFER_DST_OPTIMAL)
			region := vk.ImageCopy{
				srcSubresource = {aspectMask = {.COLOR}, layerCount = 1}, srcOffset = {i32(x0), i32(y0), 0},
				dstSubresource = {aspectMask = {.COLOR}, layerCount = 1}, extent = {x1 - x0, y1 - y0, 1},
			}
			vk.CmdCopyImage(cb, src.image, .TRANSFER_SRC_OPTIMAL, copy_.image, .TRANSFER_DST_OPTIMAL, 1, &region)
			to(cb, copy_, .SHADER_READ_ONLY_OPTIMAL)
			table := canvas_page(r, f.table) if f.kind == .Curves || f.kind == .Lut else nil
			if table != nil {
				used[f.table] = true
				to(cb, table, .SHADER_READ_ONLY_OPTIMAL)
			}
			white := page_state(r, WHITE_PAGE)
			flags := u32(1 if f.linear else 0) | canvas_curve(src.space) << 2 | canvas_curve(ps.space) << 4
			in_max := [2]i32{i32(x1 - x0) - 1, i32(y1 - y0) - 1}
			ox, oy := i32(op.sx - x0), i32(op.sy - y0) // the rectangle within the copy
			pass :: proc(r: ^Renderer, cb: vk.CommandBuffer, into: ^Page_State, pipe: vk.Pipeline, area: vk.Rect2D, input, aux: vk.DescriptorSet, push: ^Filter_Push) {
				attach := vk.RenderingAttachmentInfo{sType = .RENDERING_ATTACHMENT_INFO, imageView = into.target_view, imageLayout = .COLOR_ATTACHMENT_OPTIMAL, loadOp = .LOAD, storeOp = .STORE}
				ri := vk.RenderingInfo{sType = .RENDERING_INFO, renderArea = area, layerCount = 1, colorAttachmentCount = 1, pColorAttachments = &attach}
				if r.khr_dynamic_rendering { vk.CmdBeginRenderingKHR(cb, &ri) } else { vk.CmdBeginRendering(cb, &ri) }
				vk.CmdBindPipeline(cb, .GRAPHICS, pipe)
				vp := vk.Viewport{width = f32(into.size.x), height = f32(into.size.y), maxDepth = 1}
				scissor := area
				vk.CmdSetViewport(cb, 0, 1, &vp)
				vk.CmdSetScissor(cb, 0, 1, &scissor)
				sets := [2]vk.DescriptorSet{input, aux}
				vk.CmdBindDescriptorSets(cb, .GRAPHICS, r.filter_layout, 0, 2, &sets[0], 0, nil)
				vk.CmdPushConstants(cb, r.filter_layout, {.FRAGMENT}, 0, size_of(Filter_Push), push)
				vk.CmdDraw(cb, 3, 1, 0, 0)
				if r.khr_dynamic_rendering { vk.CmdEndRenderingKHR(cb) } else { vk.CmdEndRendering(cb) }
			}
			area := vk.Rect2D{offset = {i32(op.x), i32(op.y)}, extent = {op.w, op.h}}
			push := Filter_Push{flags = flags, a = f.sigma, b = f.amount, c = f.threshold}
			if f.kind == .Blur || f.kind == .Sharpen {
				mid := canvas_scratch(r, .RGBA32F, {op.w, y1 - y0}, 1)
				mid_pipe := canvas_filter_pipeline(r, .RGBA32F)
				if mid == nil || mid_pipe == 0 do continue
				used[r.canvas_scratch[1][.RGBA32F]] = true
				to(cb, mid, .COLOR_ATTACHMENT_OPTIMAL)
				across := push
				across.kind, across.in_off, across.in_max = 4, {ox, 0}, in_max
				pass(r, cb, mid, mid_pipe, {extent = {op.w, y1 - y0}}, copy_.set, white.set, &across)
				to(cb, mid, .SHADER_READ_ONLY_OPTIMAL)
				to(cb, ps, .COLOR_ATTACHMENT_OPTIMAL)
				down := push
				down.kind = 5 if f.kind == .Blur else 6
				down.in_off = {-i32(op.x), -i32(op.y) + oy}
				down.in_max = {i32(op.w) - 1, in_max.y}
				down.aux_off = {-i32(op.x) + ox, -i32(op.y) + oy}
				pass(r, cb, ps, pipe, area, mid.set, copy_.set, &down)
			} else {
				to(cb, ps, .COLOR_ATTACHMENT_OPTIMAL)
				push.kind = u32(f.kind) // Matrix 0, Curves 1, Convert 2, Lut 3
				push.in_off = {-i32(op.x) + ox, -i32(op.y) + oy}
				push.in_max = in_max
				switch f.kind {
				case .Matrix:
					for row in 0 ..< 4 {
						push.m[row] = {f.colors[row][0], f.colors[row][1], f.colors[row][2], f.colors[row][3]}
						push.moff[row] = f.colors[row][4]
					}
				case .Convert:
					m := space_matrix(src.space, ps.space)
					for row in 0 ..< 3 do push.m[row] = {m[row][0], m[row][1], m[row][2], 0}
				case .Curves, .Lut, .Blur, .Sharpen:
				}
				pass(r, cb, ps, pipe, area, copy_.set, table.set if table != nil else white.set, &push)
			}
			touch(&touched, op.page, op.x, op.y, op.w, op.h)
		case .Dabs:
			append(&b.staging, op.staging) // the quads: freed with the batch
			pipe := canvas_dab_pipeline(r, ps.canvas_format)
			if pipe == 0 do continue
			tip := canvas_page(r, op.tip) if op.tip != 0 else nil
			if tip != nil {
				used[op.tip] = true
				to(cb, tip, .SHADER_READ_ONLY_OPTIMAL)
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
			set := tip.set if tip != nil else page_state(r, WHITE_PAGE).set
			vk.CmdBindDescriptorSets(cb, .GRAPHICS, r.dab_layout, 0, 1, &set, 0, nil)
			push := Dab_Push{size = {f32(ps.size.x), f32(ps.size.y)}, tip = 1 if tip != nil else 0}
			vk.CmdPushConstants(cb, r.dab_layout, {.VERTEX, .FRAGMENT}, 0, size_of(Dab_Push), &push)
			offset: vk.DeviceSize
			vk.CmdBindVertexBuffers(cb, 0, 1, &op.staging.buf, &offset)
			vk.CmdDraw(cb, u32(op.count * 6), 1, 0, 0)
			if r.khr_dynamic_rendering { vk.CmdEndRenderingKHR(cb) } else { vk.CmdEndRendering(cb) }
			touch(&touched, op.page, op.x, op.y, op.w, op.h)
		case .Strokes:
			// Several runs share one buffer; only its owner hands it back.
			if op.own do append(&b.staging, op.staging)
			pipe := canvas_stroke_pipeline(r, ps.canvas_format)
			if pipe == 0 do continue
			to(cb, ps, .COLOR_ATTACHMENT_OPTIMAL)
			area := vk.Rect2D{offset = {i32(op.x), i32(op.y)}, extent = {op.w, op.h}}
			// CLEAR, not LOAD: a stroke's coverage starts from nothing and
			// the render area is exactly its rectangle, so the clear comes
			// free with the pass where a separate fill would be another pass.
			attach := vk.RenderingAttachmentInfo{sType = .RENDERING_ATTACHMENT_INFO, imageView = ps.target_view, imageLayout = .COLOR_ATTACHMENT_OPTIMAL, loadOp = .CLEAR, storeOp = .STORE, clearValue = {}}
			ri := vk.RenderingInfo{sType = .RENDERING_INFO, renderArea = area, layerCount = 1, colorAttachmentCount = 1, pColorAttachments = &attach}
			if r.khr_dynamic_rendering { vk.CmdBeginRenderingKHR(cb, &ri) } else { vk.CmdBeginRendering(cb, &ri) }
			vk.CmdBindPipeline(cb, .GRAPHICS, pipe)
			vp := vk.Viewport{width = f32(ps.size.x), height = f32(ps.size.y), maxDepth = 1}
			vk.CmdSetViewport(cb, 0, 1, &vp)
			vk.CmdSetScissor(cb, 0, 1, &area)
			push := Stroke_Push{size = {f32(ps.size.x), f32(ps.size.y)}}
			vk.CmdPushConstants(cb, r.stroke_layout, {.VERTEX, .FRAGMENT}, 0, size_of(Stroke_Push), &push)
			offset: vk.DeviceSize
			vk.CmdBindVertexBuffers(cb, 0, 1, &op.staging.buf, &offset)
			vk.CmdDraw(cb, u32(op.count * 6), 1, u32(op.first * 6), 0)
			if r.khr_dynamic_rendering { vk.CmdEndRenderingKHR(cb) } else { vk.CmdEndRendering(cb) }
			touch(&touched, op.page, op.x, op.y, op.w, op.h)
		case .Shader:
			if shader_record(r, cb, &op, ps, &used, to) do touch(&touched, op.page, op.x, op.y, op.w, op.h)
		case .Read:
			size := int(op.w) * int(op.h) * canvas_bpp(ps.canvas_format)
			buf, ok := staging_take(r, size, .Read)
			if !ok {
				append(&b.reads, Canvas_Pending_Read{id = op.id})
				continue
			}
			if ps.layout != .GENERAL do to(cb, ps, .TRANSFER_SRC_OPTIMAL)
			region := vk.BufferImageCopy{imageSubresource = {aspectMask = {.COLOR}, layerCount = 1}, imageOffset = {i32(op.x), i32(op.y), 0}, imageExtent = {op.w, op.h, 1}}
			vk.CmdCopyImageToBuffer(cb, ps.image, ps.layout, buf.buf, 1, &region)
			append(&b.reads, Canvas_Pending_Read{id = op.id, buf = buf, size = size})
		}
	}
	for p in used {
		ps := canvas_page(r, p)
		if ps == nil do continue
		if t, changed := touched[p]; changed && ps.levels > 1 {
			to(cb, ps, .TRANSFER_DST_OPTIMAL)
			mips_build(cb, ps, t) // leaves every level SHADER_READ_ONLY
			ps.layout = .SHADER_READ_ONLY_OPTIMAL
		} else {
			to(cb, ps, .SHADER_READ_ONLY_OPTIMAL)
		}
	}
	if len(b.reads) > 0 { // the copies into host memory are visible to the host once the fence signals
		barrier := vk.MemoryBarrier{sType = .MEMORY_BARRIER, srcAccessMask = {.TRANSFER_WRITE}, dstAccessMask = {.HOST_READ}}
		vk.CmdPipelineBarrier(cb, {.TRANSFER}, {.HOST}, {}, 1, &barrier, 0, nil, 0, nil)
	}
	clear(&r.canvas_ops)
	if res := vk.EndCommandBuffer(cb); res != .SUCCESS {
		fail(r, "canvas_flush: vkEndCommandBuffer: %v", res)
		canvas_batch_free(r, b)
		return
	}
	submit := vk.SubmitInfo{sType = .SUBMIT_INFO, commandBufferCount = 1, pCommandBuffers = &b.cmd}
	if res := vk.QueueSubmit(r.queue, 1, &submit, b.fence); res != .SUCCESS {
		fail(r, "canvas_flush: vkQueueSubmit: %v", res)
		canvas_batch_free(r, b)
		return
	}
	r.canvas_next_batch += 1
	b.id = r.canvas_next_batch
	append(&r.canvas_batches, b)
	return b.id, len(b.reads) > 0
}


// canvas_scratch is the backdrop copy a blend of `format` reads, at least
// `size`: kept and grown (after the device is idle: a batch in flight may
// read the old one) as blends need.
@(private)
canvas_scratch :: proc(r: ^Renderer, format: Canvas_Format, size: [2]u32, slot := 0) -> ^Page_State {
	page := r.canvas_scratch[slot][format]
	if ps := canvas_page(r, page); ps != nil && ps.size.x >= size.x && ps.size.y >= size.y do return ps
	want := size
	if ps := canvas_page(r, page); ps != nil {
		want = {max(ps.size.x, size.x), max(ps.size.y, size.y)}
		atlas_destroy(r, page) // waits for the device
	}
	r.canvas_scratch[slot][format] = canvas_make(r, want, format, .Linear, clear = false)
	return canvas_page(r, r.canvas_scratch[slot][format])
}

// canvas_dab_pipeline is the dab pass stamping onto canvases of `format`:
// one quad a dab from a vertex buffer, laid on with (ONE,
// ONE_MINUS_SRC_ALPHA), built the first time.
@(private)
canvas_dab_pipeline :: proc(r: ^Renderer, format: Canvas_Format) -> vk.Pipeline {
	if r.dab_pipelines[format] != 0 do return r.dab_pipelines[format]
	if r.dab_layout == 0 {
		push := vk.PushConstantRange{stageFlags = {.VERTEX, .FRAGMENT}, offset = 0, size = size_of(Dab_Push)}
		set := r.desc_layout
		pl := vk.PipelineLayoutCreateInfo{sType = .PIPELINE_LAYOUT_CREATE_INFO, setLayoutCount = 1, pSetLayouts = &set, pushConstantRangeCount = 1, pPushConstantRanges = &push}
		if res := vk.CreatePipelineLayout(r.device, &pl, nil, &r.dab_layout); res != .SUCCESS {
			fail(r, "canvas dabs: vkCreatePipelineLayout: %v", res)
			return 0
		}
	}
	module :: proc(r: ^Renderer, code: []u32) -> (m: vk.ShaderModule) {
		info := vk.ShaderModuleCreateInfo{sType = .SHADER_MODULE_CREATE_INFO, codeSize = len(code) * size_of(u32), pCode = raw_data(code)}
		if vk.CreateShaderModule(r.device, &info, nil, &m) != .SUCCESS do return 0
		return
	}
	vert, frag := module(r, DAB_VERT_SPV), module(r, DAB_FRAG_SPV)
	defer if vert != 0 do vk.DestroyShaderModule(r.device, vert, nil)
	defer if frag != 0 do vk.DestroyShaderModule(r.device, frag, nil)
	if vert == 0 || frag == 0 do return 0
	stages := [2]vk.PipelineShaderStageCreateInfo{
		{sType = .PIPELINE_SHADER_STAGE_CREATE_INFO, stage = {.VERTEX}, module = vert, pName = "main"},
		{sType = .PIPELINE_SHADER_STAGE_CREATE_INFO, stage = {.FRAGMENT}, module = frag, pName = "main"},
	}
	binding := vk.VertexInputBindingDescription{binding = 0, stride = size_of(Dab_Vertex), inputRate = .VERTEX}
	attrs := [3]vk.VertexInputAttributeDescription{
		{location = 0, binding = 0, format = .R32G32_SFLOAT, offset = u32(offset_of(Dab_Vertex, pos))},
		{location = 1, binding = 0, format = .R32G32_SFLOAT, offset = u32(offset_of(Dab_Vertex, centre))},
		{location = 2, binding = 0, format = .R32G32B32A32_SFLOAT, offset = u32(offset_of(Dab_Vertex, dab))},
	}
	vertex_input := vk.PipelineVertexInputStateCreateInfo{sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO, vertexBindingDescriptionCount = 1, pVertexBindingDescriptions = &binding, vertexAttributeDescriptionCount = len(attrs), pVertexAttributeDescriptions = &attrs[0]}
	assembly := vk.PipelineInputAssemblyStateCreateInfo{sType = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO, topology = .TRIANGLE_LIST}
	viewport := vk.PipelineViewportStateCreateInfo{sType = .PIPELINE_VIEWPORT_STATE_CREATE_INFO, viewportCount = 1, scissorCount = 1}
	raster := vk.PipelineRasterizationStateCreateInfo{sType = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO, polygonMode = .FILL, cullMode = {}, frontFace = .CLOCKWISE, lineWidth = 1}
	multisample := vk.PipelineMultisampleStateCreateInfo{sType = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO, rasterizationSamples = {._1}}
	over := vk.PipelineColorBlendAttachmentState{
		blendEnable = true,
		srcColorBlendFactor = .ONE, dstColorBlendFactor = .ONE_MINUS_SRC_ALPHA, colorBlendOp = .ADD,
		srcAlphaBlendFactor = .ONE, dstAlphaBlendFactor = .ONE_MINUS_SRC_ALPHA, alphaBlendOp = .ADD,
		colorWriteMask = {.R, .G, .B, .A},
	}
	blend := vk.PipelineColorBlendStateCreateInfo{sType = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO, attachmentCount = 1, pAttachments = &over}
	dyn := [2]vk.DynamicState{.VIEWPORT, .SCISSOR}
	dyn_state := vk.PipelineDynamicStateCreateInfo{sType = .PIPELINE_DYNAMIC_STATE_CREATE_INFO, dynamicStateCount = len(dyn), pDynamicStates = &dyn[0]}
	color_format := canvas_vk_format(format)
	rendering := vk.PipelineRenderingCreateInfo{sType = .PIPELINE_RENDERING_CREATE_INFO, colorAttachmentCount = 1, pColorAttachmentFormats = &color_format}
	info := vk.GraphicsPipelineCreateInfo{
		sType = .GRAPHICS_PIPELINE_CREATE_INFO, pNext = &rendering,
		stageCount = len(stages), pStages = &stages[0],
		pVertexInputState = &vertex_input, pInputAssemblyState = &assembly, pViewportState = &viewport,
		pRasterizationState = &raster, pMultisampleState = &multisample, pColorBlendState = &blend,
		pDynamicState = &dyn_state, layout = r.dab_layout,
	}
	p: vk.Pipeline
	if res := vk.CreateGraphicsPipelines(r.device, 0, 1, &info, nil, &p); res != .SUCCESS {
		fail(r, "canvas dabs: vkCreateGraphicsPipelines(%v): %v", format, res)
		return 0
	}
	r.dab_pipelines[format] = p
	return p
}

// canvas_stroke_pipeline is the stroke pass laying coverage onto canvases of
// `format`: one quad a segment from a vertex buffer, combined with
// VK_BLEND_OP_MAX so that a stroke's overlapping segments are its union
// rather than a build-up. Built the first time.
//
// It needs no descriptor set — there is no texture, only the geometry and
// the canvas's size — so its layout is push constants alone.
@(private)
canvas_stroke_pipeline :: proc(r: ^Renderer, format: Canvas_Format) -> vk.Pipeline {
	if r.stroke_pipelines[format] != 0 do return r.stroke_pipelines[format]
	if r.stroke_layout == 0 {
		push := vk.PushConstantRange{stageFlags = {.VERTEX, .FRAGMENT}, offset = 0, size = size_of(Stroke_Push)}
		pl := vk.PipelineLayoutCreateInfo{sType = .PIPELINE_LAYOUT_CREATE_INFO, pushConstantRangeCount = 1, pPushConstantRanges = &push}
		if res := vk.CreatePipelineLayout(r.device, &pl, nil, &r.stroke_layout); res != .SUCCESS {
			fail(r, "canvas strokes: vkCreatePipelineLayout: %v", res)
			return 0
		}
	}
	module :: proc(r: ^Renderer, code: []u32) -> (m: vk.ShaderModule) {
		info := vk.ShaderModuleCreateInfo{sType = .SHADER_MODULE_CREATE_INFO, codeSize = len(code) * size_of(u32), pCode = raw_data(code)}
		if vk.CreateShaderModule(r.device, &info, nil, &m) != .SUCCESS do return 0
		return
	}
	vert, frag := module(r, STROKE_VERT_SPV), module(r, STROKE_FRAG_SPV)
	defer if vert != 0 do vk.DestroyShaderModule(r.device, vert, nil)
	defer if frag != 0 do vk.DestroyShaderModule(r.device, frag, nil)
	if vert == 0 || frag == 0 do return 0
	stages := [2]vk.PipelineShaderStageCreateInfo{
		{sType = .PIPELINE_SHADER_STAGE_CREATE_INFO, stage = {.VERTEX}, module = vert, pName = "main"},
		{sType = .PIPELINE_SHADER_STAGE_CREATE_INFO, stage = {.FRAGMENT}, module = frag, pName = "main"},
	}
	binding := vk.VertexInputBindingDescription{binding = 0, stride = size_of(Stroke_Vertex), inputRate = .VERTEX}
	attrs := [3]vk.VertexInputAttributeDescription{
		{location = 0, binding = 0, format = .R32G32_SFLOAT, offset = u32(offset_of(Stroke_Vertex, pos))},
		{location = 1, binding = 0, format = .R32G32B32A32_SFLOAT, offset = u32(offset_of(Stroke_Vertex, seg))},
		{location = 2, binding = 0, format = .R32G32_SFLOAT, offset = u32(offset_of(Stroke_Vertex, radii))},
	}
	vertex_input := vk.PipelineVertexInputStateCreateInfo{sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO, vertexBindingDescriptionCount = 1, pVertexBindingDescriptions = &binding, vertexAttributeDescriptionCount = len(attrs), pVertexAttributeDescriptions = &attrs[0]}
	assembly := vk.PipelineInputAssemblyStateCreateInfo{sType = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO, topology = .TRIANGLE_LIST}
	viewport := vk.PipelineViewportStateCreateInfo{sType = .PIPELINE_VIEWPORT_STATE_CREATE_INFO, viewportCount = 1, scissorCount = 1}
	raster := vk.PipelineRasterizationStateCreateInfo{sType = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO, polygonMode = .FILL, cullMode = {}, frontFace = .CLOCKWISE, lineWidth = 1}
	multisample := vk.PipelineMultisampleStateCreateInfo{sType = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO, rasterizationSamples = {._1}}
	// The union: keep whichever of the two coverages is larger.
	union_max := vk.PipelineColorBlendAttachmentState{
		blendEnable = true,
		srcColorBlendFactor = .ONE, dstColorBlendFactor = .ONE, colorBlendOp = .MAX,
		srcAlphaBlendFactor = .ONE, dstAlphaBlendFactor = .ONE, alphaBlendOp = .MAX,
		colorWriteMask = {.R, .G, .B, .A},
	}
	blend := vk.PipelineColorBlendStateCreateInfo{sType = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO, attachmentCount = 1, pAttachments = &union_max}
	dyn := [2]vk.DynamicState{.VIEWPORT, .SCISSOR}
	dyn_state := vk.PipelineDynamicStateCreateInfo{sType = .PIPELINE_DYNAMIC_STATE_CREATE_INFO, dynamicStateCount = len(dyn), pDynamicStates = &dyn[0]}
	color_format := canvas_vk_format(format)
	rendering := vk.PipelineRenderingCreateInfo{sType = .PIPELINE_RENDERING_CREATE_INFO, colorAttachmentCount = 1, pColorAttachmentFormats = &color_format}
	info := vk.GraphicsPipelineCreateInfo{
		sType = .GRAPHICS_PIPELINE_CREATE_INFO, pNext = &rendering,
		stageCount = len(stages), pStages = &stages[0],
		pVertexInputState = &vertex_input, pInputAssemblyState = &assembly, pViewportState = &viewport,
		pRasterizationState = &raster, pMultisampleState = &multisample, pColorBlendState = &blend,
		pDynamicState = &dyn_state, layout = r.stroke_layout,
	}
	p: vk.Pipeline
	if res := vk.CreateGraphicsPipelines(r.device, 0, 1, &info, nil, &p); res != .SUCCESS {
		fail(r, "canvas strokes: vkCreateGraphicsPipelines(%v): %v", format, res)
		return 0
	}
	r.stroke_pipelines[format] = p
	return p
}

// canvas_filter_pipeline is the filter pass drawing into canvases of
// `format`, built the first time.
@(private)
canvas_filter_pipeline :: proc(r: ^Renderer, format: Canvas_Format) -> vk.Pipeline {
	if r.filter_pipelines[format] != 0 do return r.filter_pipelines[format]
	if r.filter_layout == 0 {
		push := vk.PushConstantRange{stageFlags = {.FRAGMENT}, offset = 0, size = size_of(Filter_Push)}
		sets := [2]vk.DescriptorSetLayout{r.desc_layout, r.desc_layout}
		pl := vk.PipelineLayoutCreateInfo{sType = .PIPELINE_LAYOUT_CREATE_INFO, setLayoutCount = 2, pSetLayouts = &sets[0], pushConstantRangeCount = 1, pPushConstantRanges = &push}
		if res := vk.CreatePipelineLayout(r.device, &pl, nil, &r.filter_layout); res != .SUCCESS {
			fail(r, "canvas filter: vkCreatePipelineLayout: %v", res)
			return 0
		}
	}
	p, ok := fullscreen_pipeline_create(r, FILTER_FRAG_SPV, r.filter_layout, canvas_vk_format(format))
	if ok do r.filter_pipelines[format] = p
	return p
}

// canvas_blend_pipeline is the blend pass drawing into canvases of
// `format`, built the first time.
@(private)
canvas_blend_pipeline :: proc(r: ^Renderer, format: Canvas_Format) -> vk.Pipeline {
	if r.blend_pipelines[format] != 0 do return r.blend_pipelines[format]
	if r.blend_layout == 0 {
		push := vk.PushConstantRange{stageFlags = {.FRAGMENT}, offset = 0, size = size_of(Blend_Push)}
		sets := [3]vk.DescriptorSetLayout{r.desc_layout, r.desc_layout, r.desc_layout}
		pl := vk.PipelineLayoutCreateInfo{sType = .PIPELINE_LAYOUT_CREATE_INFO, setLayoutCount = 3, pSetLayouts = &sets[0], pushConstantRangeCount = 1, pPushConstantRanges = &push}
		if res := vk.CreatePipelineLayout(r.device, &pl, nil, &r.blend_layout); res != .SUCCESS {
			fail(r, "canvas blend: vkCreatePipelineLayout: %v", res)
			return 0
		}
	}
	p, ok := fullscreen_pipeline_create(r, BLEND_FRAG_SPV, r.blend_layout, canvas_vk_format(format))
	if ok do r.blend_pipelines[format] = p
	return p
}

// canvas_waiter is what another thread needs to wait for batch `id`; zero
// for no such batch.
canvas_waiter :: proc(r: ^Renderer, id: u64) -> Canvas_Wait {
	for b in r.canvas_batches do if b.id == id do return {r.device, b.fence}
	return {}
}

// canvas_wait blocks until the batch `w` names is done, on any thread.
canvas_wait :: proc(w: Canvas_Wait) {
	if w.device == nil || w.fence == 0 do return
	fence := w.fence
	vk.WaitForFences(w.device, 1, &fence, true, max(u64))
}

// canvas_reads_take hands over batch `id`'s reads once it is done (after
// canvas_wait), each read's texels in `allocator`, and frees the batch.
// Nil while it is still running. The renderer's thread.
canvas_reads_take :: proc(r: ^Renderer, id: u64, allocator := context.allocator) -> (out: []Canvas_Read_Done, done: bool) {
	for b, i in r.canvas_batches {
		if b.id != id do continue
		if vk.GetFenceStatus(r.device, b.fence) != .SUCCESS do return nil, false
		list := make([]Canvas_Read_Done, len(b.reads), allocator)
		for rd, k in b.reads {
			list[k] = {id = rd.id}
			if rd.buf.buf == 0 do continue
			list[k].pixels = make([]u8, rd.size, allocator)
			mem.copy(raw_data(list[k].pixels), rd.buf.ptr, rd.size)
			list[k].ok = true
		}
		ordered_remove(&r.canvas_batches, i)
		canvas_batch_free(r, b)
		return list, true
	}
	return nil, true // gone: taken already
}

// canvas_retire frees the batches without reads that have finished.
@(private)
canvas_retire :: proc(r: ^Renderer) {
	for i := 0; i < len(r.canvas_batches); {
		b := r.canvas_batches[i]
		if len(b.reads) == 0 && vk.GetFenceStatus(r.device, b.fence) == .SUCCESS {
			ordered_remove(&r.canvas_batches, i)
			canvas_batch_free(r, b)
			continue
		}
		i += 1
	}
}

@(private)
canvas_batch_free :: proc(r: ^Renderer, b: ^Canvas_Batch) {
	for &s in b.staging do staging_give(r, &s)
	for &rd in b.reads do if rd.buf.buf != 0 do staging_give(r, &rd.buf)
	delete(b.staging)
	delete(b.reads)
	if b.fence != 0 do vk.DestroyFence(r.device, b.fence, nil)
	if b.cmd != nil do vk.FreeCommandBuffers(r.device, r.cmd_pool, 1, &b.cmd)
	free(b)
}

@(private)
canvas_ops_drop :: proc(r: ^Renderer) {
	for &op in r.canvas_ops do if op.kind == .Write || op.kind == .Dabs || (op.kind == .Strokes && op.own) do staging_give(r, &op.staging)
	clear(&r.canvas_ops)
}

// canvas_idle waits for every canvas batch submitted to finish (the run is
// ending).
canvas_idle :: proc(r: ^Renderer) {
	if r.device != nil do vk.DeviceWaitIdle(r.device)
}

// canvas_shutdown frees every batch and queued op (the renderer is going).
@(private)
canvas_shutdown :: proc(r: ^Renderer) {
	if r.device != nil do vk.DeviceWaitIdle(r.device)
	canvas_ops_drop(r)
	for b in r.canvas_batches do canvas_batch_free(r, b)
	staging_shutdown(r) // after the two above: both hand their buffers back to it
	for p in r.blend_pipelines do if p != 0 do vk.DestroyPipeline(r.device, p, nil)
	if r.blend_layout != 0 do vk.DestroyPipelineLayout(r.device, r.blend_layout, nil)
	r.blend_pipelines, r.blend_layout = {}, 0
	for p in r.transform_pipelines do if p != 0 do vk.DestroyPipeline(r.device, p, nil)
	if r.transform_layout != 0 do vk.DestroyPipelineLayout(r.device, r.transform_layout, nil)
	r.transform_pipelines, r.transform_layout = {}, 0
	for p in r.filter_pipelines do if p != 0 do vk.DestroyPipeline(r.device, p, nil)
	if r.filter_layout != 0 do vk.DestroyPipelineLayout(r.device, r.filter_layout, nil)
	r.filter_pipelines, r.filter_layout = {}, 0
	for p in r.dab_pipelines do if p != 0 do vk.DestroyPipeline(r.device, p, nil)
	for p in r.stroke_pipelines do if p != 0 do vk.DestroyPipeline(r.device, p, nil)
	if r.stroke_layout != 0 do vk.DestroyPipelineLayout(r.device, r.stroke_layout, nil)
	if r.dab_layout != 0 do vk.DestroyPipelineLayout(r.device, r.dab_layout, nil)
	r.dab_pipelines, r.dab_layout = {}, 0
	r.stroke_pipelines, r.stroke_layout = {}, 0
	for &st in r.shaders do if st.used do shader_state_destroy(r, &st)
	delete(r.shaders)
	r.shaders = nil
	if r.storage_layout != 0 do vk.DestroyDescriptorSetLayout(r.device, r.storage_layout, nil)
	for pool in r.storage_pools do vk.DestroyDescriptorPool(r.device, pool, nil)
	delete(r.storage_pools)
	r.storage_layout, r.storage_pools = 0, nil
	delete(r.canvas_batches)
	delete(r.canvas_ops)
	r.canvas_batches, r.canvas_ops = nil, nil
}

