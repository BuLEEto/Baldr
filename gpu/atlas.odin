#+build !darwin
// atlas.odin — atlas pages are VkImages sampled by Glyph commands. Alpha8 →
// R8_UNORM (coverage), RGBA8 → R8G8B8A8_SRGB (emoji/icon bitmaps are
// sRGB-encoded; sampling yields linear). Uploads are staged into host-visible
// buffers and copied, with layout barriers, at the start of the next render()
// on any target; staging buffers are retired when that frame's fence signals.
// A picture's own page (picture_create) is one RGBA8 image with a mip chain,
// rebuilt by blits after each upload and sampled trilinearly.
//
// Page 1 (WHITE_PAGE) is a built-in 1×1 Alpha8 page holding 0xFF. Glyph.page
// 0 or any invalid page is drawn with it, so a bad handle tints a solid quad
// instead of crashing; it also lets Quads share a batch with any glyph page.
package gpu

import "core:mem"
import vk "vendor:vulkan"

// WHITE_PAGE is the built-in 1×1 white Alpha8 page (created with the device).

// DESC_POOL_SETS is how many pages one descriptor pool holds; pools are chained.
DESC_POOL_SETS :: 64

Page_State :: struct {
	used:        bool,
	format:      Page_Format,
	size:        [2]u32,
	image:       vk.Image,
	memory:      vk.DeviceMemory,
	view:        vk.ImageView,
	set:         vk.DescriptorSet,
	pool:        vk.DescriptorPool, // pool `set` was allocated from
	initialized: bool, // image layout is SHADER_READ_ONLY_OPTIMAL (set by the first render after creation)
	levels:      u32,  // mip levels: 1 for an atlas page; a picture's whole chain, rebuilt from level 0 after each upload
	// a canvas (canvas.odin): its format and colour space, the view it is
	// drawn into through (level 0), and every level's layout between flushes
	canvas:        bool,
	canvas_format: Canvas_Format,
	space:         Color_Space,
	target_view:   vk.ImageView,
	layout:        vk.ImageLayout,
	storage:       bool,              // a compute shader can write it (shader.odin)
	storage_set:   vk.DescriptorSet,  // …through this, made the first time one does
	storage_pool:  vk.DescriptorPool,
	// a GPU buffer imported from another process (dmabuf_linux.odin): sampled
	// only, kept in GENERAL, and owned by our queue family only while a frame
	// reads it. `read_*` name the latest frame that sampled it, which is what
	// canvas_import_idle answers from.
	imported:        bool,
	read_serial:     u64,
	read_target:     Target,
	read_slot:       u8,
	released_serial: u64, // …and the frame ownership was last handed back in
}

Upload :: struct {
	page:       Page,
	x, y, w, h: u32,
	staging:    Buffer,
}

@(private)
page_state :: proc(r: ^Renderer, p: Page) -> ^Page_State {
	i := int(p) - 1
	if i < 0 || i >= len(r.pages) || !r.pages[i].used { return nil }
	return &r.pages[i]
}

// page_bpp is bytes per pixel of a page format.
page_bpp :: proc(f: Page_Format) -> int {
	switch f {
	case .Alpha8: return 1
	case .RGBA8:  return 4
	}
	return 1
}

@(private)
page_vk_format :: proc(f: Page_Format) -> vk.Format {
	switch f {
	case .Alpha8: return .R8_UNORM
	case .RGBA8:  return .R8G8B8A8_SRGB
	}
	return .R8_UNORM
}

// atlas_create allocates a `size` page of `format` and its descriptor set.
// Contents are undefined until atlas_upload; the page is sampleable from the
// first render() after creation. Requires the device, i.e. at least one
// target_add must have succeeded; returns 0 otherwise, or when `size` is 0 /
// exceeds the device limit / the allocation fails.
atlas_create :: proc(r: ^Renderer, format: Page_Format, size: [2]u32) -> Page {
	return page_create(r, format, size, 1)
}

// picture_create allocates an RGBA8 page for one picture of `size` with a
// full mip chain, sampled trilinearly: a picture bigger than an atlas page is
// drawn from its own pixels, and one drawn smaller than it is stays smooth.
// atlas_upload fills level 0 as for any page; the render that
// lands an upload then rebuilds the smaller levels from it on the GPU, each a
// linear-light halving of the one above. Where the device cannot blit RGBA8
// sRGB with a linear filter the page has one level (plain bilinear). Returns
// 0 as atlas_create does: no device, a size past the device's limit, or the
// allocation failing — draw the picture another way then.
picture_create :: proc(r: ^Renderer, size: [2]u32) -> Page {
	levels: u32 = 1
	if r.blit_mips {
		for m := max(size.x, size.y); m > 1; m >>= 1 do levels += 1
	}
	return page_create(r, .RGBA8, size, levels)
}

@(private)
page_create :: proc(r: ^Renderer, format: Page_Format, size: [2]u32, levels: u32) -> Page {
	if r.device == nil { fail(r, "atlas_create before the first target_add (no device)"); return 0 }
	if size.x == 0 || size.y == 0 || size.x > r.max_image_dim || size.y > r.max_image_dim {
		fail(r, "atlas_create: bad size %dx%d (limit %d)", size.x, size.y, r.max_image_dim)
		return 0
	}
	slot := -1
	for &p, i in r.pages {
		if !p.used { slot = i; break }
	}
	if slot < 0 {
		append(&r.pages, Page_State{})
		slot = len(r.pages) - 1
	}
	ps := &r.pages[slot]
	ps^ = {used = true, format = format, size = size, levels = max(levels, 1)}

	info := vk.ImageCreateInfo{
		sType         = .IMAGE_CREATE_INFO,
		imageType     = .D2,
		format        = page_vk_format(format),
		extent        = {size.x, size.y, 1},
		mipLevels     = ps.levels,
		arrayLayers   = 1,
		samples       = {._1},
		tiling        = .OPTIMAL,
		usage         = {.SAMPLED, .TRANSFER_DST, .TRANSFER_SRC} if ps.levels > 1 else {.SAMPLED, .TRANSFER_DST},
		sharingMode   = .EXCLUSIVE,
		initialLayout = .UNDEFINED,
	}
	if res := vk.CreateImage(r.device, &info, nil, &ps.image); res != .SUCCESS {
		fail(r, "vkCreateImage(%dx%d %v): %v", size.x, size.y, format, res)
		ps^ = {}
		return 0
	}
	req: vk.MemoryRequirements
	vk.GetImageMemoryRequirements(r.device, ps.image, &req)
	type_index, found := find_memory_type(r, req.memoryTypeBits, {.DEVICE_LOCAL})
	if !found { type_index, found = find_memory_type(r, req.memoryTypeBits, {}) }
	if !found {
		fail(r, "atlas_create: no memory type for image")
		page_state_destroy(r, ps)
		return 0
	}
	alloc := vk.MemoryAllocateInfo{sType = .MEMORY_ALLOCATE_INFO, allocationSize = req.size, memoryTypeIndex = type_index}
	if res := vk.AllocateMemory(r.device, &alloc, nil, &ps.memory); res != .SUCCESS {
		fail(r, "vkAllocateMemory(image %d bytes): %v", req.size, res)
		page_state_destroy(r, ps)
		return 0
	}
	if res := vk.BindImageMemory(r.device, ps.image, ps.memory, 0); res != .SUCCESS {
		fail(r, "vkBindImageMemory: %v", res)
		page_state_destroy(r, ps)
		return 0
	}
	vi := vk.ImageViewCreateInfo{
		sType            = .IMAGE_VIEW_CREATE_INFO,
		image            = ps.image,
		viewType         = .D2,
		format           = info.format,
		subresourceRange = {aspectMask = {.COLOR}, levelCount = ps.levels, layerCount = 1},
	}
	if res := vk.CreateImageView(r.device, &vi, nil, &ps.view); res != .SUCCESS {
		fail(r, "vkCreateImageView(atlas): %v", res)
		page_state_destroy(r, ps)
		return 0
	}
	set, pool, ok := desc_set_alloc(r)
	if !ok {
		page_state_destroy(r, ps)
		return 0
	}
	ps.set, ps.pool = set, pool
	img_info := vk.DescriptorImageInfo{sampler = r.mip_sampler if ps.levels > 1 else r.sampler, imageView = ps.view, imageLayout = .SHADER_READ_ONLY_OPTIMAL}
	write := vk.WriteDescriptorSet{
		sType           = .WRITE_DESCRIPTOR_SET,
		dstSet          = ps.set,
		dstBinding      = 0,
		descriptorCount = 1,
		descriptorType  = .COMBINED_IMAGE_SAMPLER,
		pImageInfo      = &img_info,
	}
	vk.UpdateDescriptorSets(r.device, 1, &write, 0, nil)
	return Page(slot + 1)
}

// atlas_upload copies `pixels` (row-major, tightly packed, w*h*bpp bytes,
// bpp = 1 for Alpha8 / 4 for RGBA8) into the rectangle (x, y, w, h) of
// `page`. The bytes are copied into a staging buffer immediately (the caller
// may reuse `pixels` on return) and land on the GPU at the start of the next
// render() of any target, before its draws. Out-of-range rectangles, short
// pixel slices and unknown pages are ignored (logged).
atlas_upload :: proc(r: ^Renderer, page: Page, x, y, w, h: u32, pixels: []u8) {
	ps := page_state(r, page)
	if ps == nil { fail(r, "atlas_upload: unknown page %d", page); return }
	if w == 0 || h == 0 { return }
	if x + w > ps.size.x || y + h > ps.size.y {
		fail(r, "atlas_upload: rect %d,%d %dx%d outside page %d (%dx%d)", x, y, w, h, page, ps.size.x, ps.size.y)
		return
	}
	need := int(w) * int(h) * page_bpp(ps.format)
	if len(pixels) < need {
		fail(r, "atlas_upload: %d bytes given, %d needed", len(pixels), need)
		return
	}
	staging, ok := buffer_create(r, need, {.TRANSFER_SRC}, true)
	if !ok { return }
	mem.copy(staging.ptr, raw_data(pixels), need)
	append(&r.uploads, Upload{page = page, x = x, y = y, w = w, h = h, staging = staging})
}

// atlas_destroy frees a page and its descriptor set. It waits for the device
// to go idle first (a frame in flight may still sample the page), so call it
// rarely (eviction), not per frame. Pending uploads to the page are dropped.
// WHITE_PAGE cannot be destroyed.
atlas_destroy :: proc(r: ^Renderer, page: Page) {
	if page == WHITE_PAGE { return }
	ps := page_state(r, page)
	if ps == nil { return }
	vk.DeviceWaitIdle(r.device)
	for i := 0; i < len(r.canvas_ops); { // work queued on a canvas going away
		if r.canvas_ops[i].page == page || r.canvas_ops[i].src == page {
			if r.canvas_ops[i].kind == .Write do buffer_destroy(r, &r.canvas_ops[i].staging)
			ordered_remove(&r.canvas_ops, i)
		} else {
			i += 1
		}
	}
	for i := 0; i < len(r.uploads); {
		if r.uploads[i].page == page {
			buffer_destroy(r, &r.uploads[i].staging)
			unordered_remove(&r.uploads, i)
		} else {
			i += 1
		}
	}
	page_state_destroy(r, ps)
}

@(private)
page_state_destroy :: proc(r: ^Renderer, ps: ^Page_State) {
	if ps.set != 0 { vk.FreeDescriptorSets(r.device, ps.pool, 1, &ps.set) }
	if ps.storage_set != 0 { vk.FreeDescriptorSets(r.device, ps.storage_pool, 1, &ps.storage_set) }
	if ps.view != 0 { vk.DestroyImageView(r.device, ps.view, nil) }
	if ps.target_view != 0 { vk.DestroyImageView(r.device, ps.target_view, nil) }
	if ps.image != 0 { vk.DestroyImage(r.device, ps.image, nil) }
	if ps.memory != 0 { vk.FreeMemory(r.device, ps.memory, nil) }
	ps^ = {}
}

// white_page_create makes WHITE_PAGE (must be the first page ever created).
@(private)
white_page_create :: proc(r: ^Renderer) -> Page {
	p := atlas_create(r, .Alpha8, {1, 1})
	if p != 0 {
		white := [1]u8{0xFF}
		atlas_upload(r, p, 0, 0, 1, 1, white[:])
	}
	return p
}

// desc_set_alloc takes a set from the newest pool, opening a new pool when it
// is exhausted.
@(private)
desc_set_alloc :: proc(r: ^Renderer) -> (set: vk.DescriptorSet, pool: vk.DescriptorPool, ok: bool) {
	try_alloc :: proc(r: ^Renderer, pool: vk.DescriptorPool) -> (vk.DescriptorSet, bool) {
		layout := r.desc_layout
		info := vk.DescriptorSetAllocateInfo{
			sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
			descriptorPool     = pool,
			descriptorSetCount = 1,
			pSetLayouts        = &layout,
		}
		set: vk.DescriptorSet
		res := vk.AllocateDescriptorSets(r.device, &info, &set)
		return set, res == .SUCCESS
	}
	if n := len(r.desc_pools); n > 0 {
		if s, sok := try_alloc(r, r.desc_pools[n - 1]); sok { return s, r.desc_pools[n - 1], true }
	}
	size := vk.DescriptorPoolSize{type = .COMBINED_IMAGE_SAMPLER, descriptorCount = DESC_POOL_SETS}
	info := vk.DescriptorPoolCreateInfo{
		sType         = .DESCRIPTOR_POOL_CREATE_INFO,
		flags         = {.FREE_DESCRIPTOR_SET},
		maxSets       = DESC_POOL_SETS,
		poolSizeCount = 1,
		pPoolSizes    = &size,
	}
	if res := vk.CreateDescriptorPool(r.device, &info, nil, &pool); res != .SUCCESS {
		fail(r, "vkCreateDescriptorPool: %v", res)
		return 0, 0, false
	}
	append(&r.desc_pools, pool)
	s, sok := try_alloc(r, pool)
	if !sok {
		fail(r, "vkAllocateDescriptorSets failed on a fresh pool")
		return 0, 0, false
	}
	return s, pool, true
}

// record_uploads writes the pending atlas copies into `cb` and moves their
// staging buffers to `frame.retire`. A picture's mip levels are rebuilt from
// its level 0 after its copies. Pages created since the last render that
// have no upload get their UNDEFINED → SHADER_READ_ONLY transition here so
// sampling them is always legal.
@(private)
record_uploads :: proc(r: ^Renderer, cb: vk.CommandBuffer, frame: ^Frame) {
	cur: ^Page_State // page currently in TRANSFER_DST_OPTIMAL
	touched: [4]u32  // x0, y0, x1, y1: what its copies covered, which is all its mip levels need redoing
	done :: proc(cb: vk.CommandBuffer, ps: ^Page_State, touched: [4]u32) {
		if ps.levels > 1 do mips_build(cb, ps, touched)
		else do page_barrier(cb, ps.image, .TRANSFER_DST_OPTIMAL, .SHADER_READ_ONLY_OPTIMAL)
	}
	for &u in r.uploads {
		ps := page_state(r, u.page)
		if ps == nil {
			buffer_destroy(r, &u.staging)
			continue
		}
		if ps != cur {
			if cur != nil do done(cb, cur, touched)
			old: vk.ImageLayout = .SHADER_READ_ONLY_OPTIMAL if ps.initialized else .UNDEFINED
			page_barrier(cb, ps.image, old, .TRANSFER_DST_OPTIMAL, 0, ps.levels)
			ps.initialized = true
			cur = ps
			touched = {u.x, u.y, u.x + u.w, u.y + u.h}
		} else {
			touched = {min(touched[0], u.x), min(touched[1], u.y), max(touched[2], u.x + u.w), max(touched[3], u.y + u.h)}
		}
		region := vk.BufferImageCopy{
			bufferOffset      = 0,
			bufferRowLength   = 0, // tightly packed
			bufferImageHeight = 0,
			imageSubresource  = {aspectMask = {.COLOR}, mipLevel = 0, baseArrayLayer = 0, layerCount = 1},
			imageOffset       = {i32(u.x), i32(u.y), 0},
			imageExtent       = {u.w, u.h, 1},
		}
		vk.CmdCopyBufferToImage(cb, u.staging.buf, ps.image, .TRANSFER_DST_OPTIMAL, 1, &region)
		append(&frame.retire, u.staging)
		u.staging = {}
	}
	if cur != nil do done(cb, cur, touched)
	clear(&r.uploads)

	for &ps in r.pages {
		if ps.used && !ps.initialized {
			page_barrier(cb, ps.image, .UNDEFINED, .SHADER_READ_ONLY_OPTIMAL, 0, ps.levels)
			ps.initialized = true
		}
	}
}

// mips_build rebuilds a picture's smaller levels from level 0 where
// `touched` (x0, y0, x1, y1 in level 0) changed, every level being in
// TRANSFER_DST_OPTIMAL: each is a linear-filtered blit of the one above at
// half its size (an sRGB blit decodes, filters in linear light and encodes
// again, so the average is of light, not of stored values). Only the region
// over what changed is blitted, widened to whole 2 × 2 blocks — a brush dab
// redoes a few blocks a level, not a 4K picture's whole chain; a level whose
// side does not halve exactly (an odd size) is blitted whole,
// so a partial rebuild is the same as a full one. Leaves every level
// SHADER_READ_ONLY_OPTIMAL.
@(private)
mips_build :: proc(cb: vk.CommandBuffer, ps: ^Page_State, touched: [4]u32) {
	w, h := i32(ps.size.x), i32(ps.size.y)
	r := [4]i32{i32(touched[0]), i32(touched[1]), i32(touched[2]), i32(touched[3])}
	for level in 1 ..< ps.levels {
		page_barrier(cb, ps.image, .TRANSFER_DST_OPTIMAL, .TRANSFER_SRC_OPTIMAL, level - 1, 1)
		nw, nh := max(w / 2, 1), max(h / 2, 1)
		src, dst: [4]i32
		if w == 2 * nw && h == 2 * nh { // halves exactly: the blocks over what changed
			src = {r[0] &~ 1, r[1] &~ 1, min((r[2] + 1) &~ 1, w), min((r[3] + 1) &~ 1, h)}
			dst = {src[0] / 2, src[1] / 2, src[2] / 2, src[3] / 2}
		} else { // an odd side: the whole level, as a full rebuild blits it
			src, dst = {0, 0, w, h}, {0, 0, nw, nh}
		}
		if dst[2] > dst[0] && dst[3] > dst[1] {
			blit := vk.ImageBlit{
				srcSubresource = {aspectMask = {.COLOR}, mipLevel = level - 1, layerCount = 1},
				srcOffsets     = {{src[0], src[1], 0}, {src[2], src[3], 1}},
				dstSubresource = {aspectMask = {.COLOR}, mipLevel = level, layerCount = 1},
				dstOffsets     = {{dst[0], dst[1], 0}, {dst[2], dst[3], 1}},
			}
			vk.CmdBlitImage(cb, ps.image, .TRANSFER_SRC_OPTIMAL, ps.image, .TRANSFER_DST_OPTIMAL, 1, &blit, .LINEAR)
		}
		page_barrier(cb, ps.image, .TRANSFER_SRC_OPTIMAL, .SHADER_READ_ONLY_OPTIMAL, level - 1, 1)
		w, h, r = nw, nh, dst
	}
	page_barrier(cb, ps.image, .TRANSFER_DST_OPTIMAL, .SHADER_READ_ONLY_OPTIMAL, ps.levels - 1, 1)
}

// page_barrier transitions `levels` mip levels of an atlas image from
// `level` between its layouts, with the matching stage/access masks. A barrier orders against every earlier
// submission on the queue, so a still-executing previous frame sampling the
// page is waited for before the copy overwrites it.
@(private)
page_barrier :: proc(cb: vk.CommandBuffer, image: vk.Image, old, new: vk.ImageLayout, level: u32 = 0, levels: u32 = 1) {
	src_stage, dst_stage: vk.PipelineStageFlags
	src_access, dst_access: vk.AccessFlags
	#partial switch old {
	case .UNDEFINED:                src_stage = {.TOP_OF_PIPE};     src_access = {}
	case .SHADER_READ_ONLY_OPTIMAL: src_stage = {.FRAGMENT_SHADER, .COMPUTE_SHADER}; src_access = {.SHADER_READ}
	case .TRANSFER_DST_OPTIMAL:     src_stage = {.TRANSFER};        src_access = {.TRANSFER_WRITE}
	case .TRANSFER_SRC_OPTIMAL:     src_stage = {.TRANSFER};        src_access = {.TRANSFER_READ}
	case:                           src_stage = {.ALL_COMMANDS};    src_access = {.MEMORY_WRITE}
	}
	#partial switch new {
	case .TRANSFER_DST_OPTIMAL:     dst_stage = {.TRANSFER};        dst_access = {.TRANSFER_WRITE}
	case .TRANSFER_SRC_OPTIMAL:     dst_stage = {.TRANSFER};        dst_access = {.TRANSFER_READ}
	case .SHADER_READ_ONLY_OPTIMAL: dst_stage = {.FRAGMENT_SHADER, .COMPUTE_SHADER}; dst_access = {.SHADER_READ}
	case:                           dst_stage = {.ALL_COMMANDS};    dst_access = {.MEMORY_READ, .MEMORY_WRITE}
	}
	b := vk.ImageMemoryBarrier{
		sType               = .IMAGE_MEMORY_BARRIER,
		srcAccessMask       = src_access,
		dstAccessMask       = dst_access,
		oldLayout           = old,
		newLayout           = new,
		srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		image               = image,
		subresourceRange    = {aspectMask = {.COLOR}, baseMipLevel = level, levelCount = levels, layerCount = 1},
	}
	vk.CmdPipelineBarrier(cb, src_stage, dst_stage, {}, 0, nil, 0, nil, 1, &b)
}
