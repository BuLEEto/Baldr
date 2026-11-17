#+build linux
// dmabuf_linux.odin — a GPU buffer another process made, imported as a page
// and sampled like any other.
//
// The case it is for: video. A helper process decodes in hardware and draws
// each frame on the same card, into a small ring of buffers it shares as
// dmabufs over a socket. Handing those frames over as pixels instead costs
// two copies of 33 MB sixty times a second at 4K60 — around three cores,
// against a few percent of one when the buffer is imported. Nothing about
// the toolkit's drawing changes; what changes is who allocated the memory.
//
// Three things make an imported image different from one of ours:
//
//   * It is sampled, never written. The producer owns the contents. The
//     page is refused by every canvas operation, and the image is created
//     with SAMPLED usage alone.
//   * Its layout is the other API's business. The image is created with
//     an explicit DRM format modifier and kept in GENERAL, the layout a
//     foreign queue hands over and expects back; its descriptor says GENERAL
//     too. A frame that samples it takes queue-family ownership from
//     VK_QUEUE_FAMILY_FOREIGN_EXT before drawing and gives it back after,
//     which is what tells the driver the other API wrote it.
//   * Nothing is implicit. The producer's drawing is not finished when it
//     hands the fd over, so each frame comes with a sync_file to wait on
//     (canvas_acquire_fence imports it as a semaphore the next submit waits
//     on), and the producer must not overwrite a buffer we are still reading
//     (canvas_import_idle says when a frame that sampled it has finished).
//
// The import path needs five device extensions, all optional: without them
// every call here refuses and the app copies its frames in instead.
package gpu

import "core:c"
import "core:fmt"
import "core:sys/linux"
import vk "vendor:vulkan"

// Dmabuf_State is the renderer's side: whether the extensions are there, the
// card, and the acquire semaphores waiting for the next submit.
@(private)
Dmabuf_State :: struct {
	caps:    Dmabuf_Caps,
	pending: [dynamic]vk.Semaphore, // imported sync_files the next submit waits on
	free:    [dynamic]vk.Semaphore, // …and ones a finished frame handed back
	said:    bool,                  // a refusal has been explained once
}

// dmabuf_extensions appends the device extensions importing needs, when the
// device has them all. Importing is optional: a device without them is used
// as usual and canvas_import_dmabuf refuses, so an app falls back to copying
// its frames in.
@(private)
dmabuf_extensions :: proc(r: ^Renderer, exts: ^[dynamic]cstring) {
	want := [?]cstring{
		vk.KHR_EXTERNAL_MEMORY_FD_EXTENSION_NAME,      // import memory from a file descriptor
		vk.EXT_EXTERNAL_MEMORY_DMA_BUF_EXTENSION_NAME, // …and that descriptor may be a dmabuf
		vk.EXT_IMAGE_DRM_FORMAT_MODIFIER_EXTENSION_NAME, // an image laid out the way the producer laid it out
		vk.KHR_EXTERNAL_SEMAPHORE_FD_EXTENSION_NAME,   // a sync_file as a semaphore, both ways
		vk.EXT_QUEUE_FAMILY_FOREIGN_EXTENSION_NAME,    // handing ownership to and from the other API
	}
	for name in want {
		if !has_device_ext(r.phys, string(name)) {
			fmt.eprintfln("gpu: no importing of GPU buffers from other processes: this device has no %s", name)
			return
		}
	}
	for name in want do append(exts, name)
	r.dmabuf.caps.import_ok = true
}

// dmabuf_node reads which card this device is, as DRM device numbers
// (VK_EXT_physical_device_drm). Called once the physical device is chosen.
@(private)
dmabuf_node :: proc(r: ^Renderer) {
	if !has_device_ext(r.phys, vk.EXT_PHYSICAL_DEVICE_DRM_EXTENSION_NAME) do return
	drm := vk.PhysicalDeviceDrmPropertiesEXT{sType = .PHYSICAL_DEVICE_DRM_PROPERTIES_EXT}
	props := vk.PhysicalDeviceProperties2{sType = .PHYSICAL_DEVICE_PROPERTIES_2, pNext = &drm}
	vk.GetPhysicalDeviceProperties2(r.phys, &props)
	if !drm.hasRender do return
	r.dmabuf.caps.render_node = true
	r.dmabuf.caps.render_major, r.dmabuf.caps.render_minor = drm.renderMajor, drm.renderMinor
}

// dmabuf_caps is what this renderer can import and which card it draws on.
dmabuf_caps :: proc(r: ^Renderer) -> Dmabuf_Caps {
	return r.dmabuf.caps if r != nil else {}
}

// dmabuf_vk_format is the Vulkan format a fourcc's bytes are, and whether the
// alpha channel is to be read or taken as opaque. The DRM names are
// little-endian byte order and Vulkan's are channel order, so ABGR8888 —
// bytes R, G, B, A — is R8G8B8A8, and ARGB8888 is B8G8R8A8.
//
// UNORM rather than SRGB: an imported buffer is drawn as a canvas, and a
// canvas's colour space is undone in the shader, as it is for every other
// canvas. Reading it through an sRGB view as well would decode it twice.
@(private)
dmabuf_vk_format :: proc "contextless" (fourcc: u32) -> (format: vk.Format, opaque: bool, ok: bool) {
	switch fourcc {
	case DRM_FORMAT_ABGR8888: return .R8G8B8A8_UNORM, false, true
	case DRM_FORMAT_XBGR8888: return .R8G8B8A8_UNORM, true, true
	case DRM_FORMAT_ARGB8888: return .B8G8R8A8_UNORM, false, true
	case DRM_FORMAT_XRGB8888: return .B8G8R8A8_UNORM, true, true
	}
	return .UNDEFINED, false, false
}

// dmabuf_modifiers fills `out` with the modifiers this device can import
// `fourcc` in, most preferred first, and returns how many there are — which
// may be more than `out` held, so a caller with a small buffer can ask again.
// 0 for a format it cannot import at all, or with no importing on this
// device. A producer needs this before it allocates: a buffer laid out a way
// we cannot import has to be copied. Only single-plane modifiers are listed,
// each checked by asking whether an image could be created with it from a
// dmabuf, since a format table saying "sampled" is not the same answer.
dmabuf_modifiers :: proc(r: ^Renderer, fourcc: u32, out: []u64) -> int {
	if r == nil || r.device == nil || !r.dmabuf.caps.import_ok do return 0
	format, _, known := dmabuf_vk_format(fourcc)
	if !known do return 0

	list := vk.DrmFormatModifierPropertiesListEXT{sType = .DRM_FORMAT_MODIFIER_PROPERTIES_LIST_EXT}
	props := vk.FormatProperties2{sType = .FORMAT_PROPERTIES_2, pNext = &list}
	vk.GetPhysicalDeviceFormatProperties2(r.phys, format, &props)
	if list.drmFormatModifierCount == 0 do return 0
	mods := make([]vk.DrmFormatModifierPropertiesEXT, list.drmFormatModifierCount, context.temp_allocator)
	list.pDrmFormatModifierProperties = raw_data(mods)
	vk.GetPhysicalDeviceFormatProperties2(r.phys, format, &props)

	n := 0
	for m in mods {
		if m.drmFormatModifierPlaneCount != 1 do continue // one plane only: see the file comment
		if .SAMPLED_IMAGE not_in m.drmFormatModifierTilingFeatures do continue
		if !dmabuf_image_ok(r, format, m.drmFormatModifier) do continue
		if n < len(out) do out[n] = m.drmFormatModifier
		n += 1
	}
	return n
}

// dmabuf_image_ok asks the driver the question that matters: could an image
// be created with this modifier, from memory imported as a dmabuf, and
// sampled? A modifier the format table lists can still fail here.
@(private)
dmabuf_image_ok :: proc(r: ^Renderer, format: vk.Format, modifier: u64) -> bool {
	mod := vk.PhysicalDeviceImageDrmFormatModifierInfoEXT{
		sType             = .PHYSICAL_DEVICE_IMAGE_DRM_FORMAT_MODIFIER_INFO_EXT,
		drmFormatModifier = modifier,
		sharingMode       = .EXCLUSIVE,
	}
	ext := vk.PhysicalDeviceExternalImageFormatInfo{
		sType      = .PHYSICAL_DEVICE_EXTERNAL_IMAGE_FORMAT_INFO,
		pNext      = &mod,
		handleType = {.DMA_BUF_EXT},
	}
	info := vk.PhysicalDeviceImageFormatInfo2{
		sType  = .PHYSICAL_DEVICE_IMAGE_FORMAT_INFO_2,
		pNext  = &ext,
		format = format,
		type   = .D2,
		tiling = .DRM_FORMAT_MODIFIER_EXT,
		usage  = {.SAMPLED},
	}
	external := vk.ExternalImageFormatProperties{sType = .EXTERNAL_IMAGE_FORMAT_PROPERTIES}
	out := vk.ImageFormatProperties2{sType = .IMAGE_FORMAT_PROPERTIES_2, pNext = &external}
	if vk.GetPhysicalDeviceImageFormatProperties2(r.phys, &info, &out) != .SUCCESS do return false
	return .IMPORTABLE in external.externalMemoryProperties.externalMemoryFeatures
}

// canvas_import_dmabuf imports `buf` as a page that can be drawn as a canvas
// of its own and nothing else: no write, fill, blend or filter touches it,
// because the memory belongs to whoever made it. The descriptor is
// duplicated, so the caller closes its own fd whenever it likes; the
// duplicate goes with the page. 0 when this device cannot import, the format
// or modifier is not one of ours, the size is impossible, or the driver
// refuses the memory; the caller then copies its frames in instead, and the
// first refusal is explained on stderr.
canvas_import_dmabuf :: proc(r: ^Renderer, buf: Dmabuf) -> Page {
	if r == nil || r.device == nil do return 0
	if !r.dmabuf.caps.import_ok {
		dmabuf_refuse(r, "this device cannot import buffers from other processes")
		return 0
	}
	format, is_opaque, known := dmabuf_vk_format(buf.fourcc)
	if !known {
		dmabuf_refuse(r, "fourcc %08x is not one of the four single-plane 8-bit formats", buf.fourcc)
		return 0
	}
	if buf.width == 0 || buf.height == 0 || buf.width > r.max_image_dim || buf.height > r.max_image_dim {
		dmabuf_refuse(r, "%d x %d cannot be imported (the limit is %d)", buf.width, buf.height, r.max_image_dim)
		return 0
	}
	if buf.fd < 0 {
		dmabuf_refuse(r, "no file descriptor to import")
		return 0
	}
	if u64(buf.stride) < u64(buf.width) * 4 {
		dmabuf_refuse(r, "a stride of %d cannot hold %d texels of 4 bytes", buf.stride, buf.width)
		return 0
	}

	slot := -1
	for &p, i in r.pages do if !p.used { slot = i; break }
	if slot < 0 {
		append(&r.pages, Page_State{})
		slot = len(r.pages) - 1
	}
	ps := &r.pages[slot]
	ps^ = {
		used = true, format = .RGBA8, size = {buf.width, buf.height}, levels = 1,
		canvas = true, canvas_format = .RGBA8, space = .sRGB,
		imported = true, layout = .GENERAL, initialized = true,
	}

	// The image, laid out the way the producer laid it out. One plane, its
	// offset and row pitch as given: a tiled buffer's rows are not width × 4.
	plane := vk.SubresourceLayout{offset = vk.DeviceSize(buf.offset), rowPitch = vk.DeviceSize(buf.stride)}
	ext_img := vk.ExternalMemoryImageCreateInfo{
		sType       = .EXTERNAL_MEMORY_IMAGE_CREATE_INFO,
		handleTypes = {.DMA_BUF_EXT},
	}
	mod_img := vk.ImageDrmFormatModifierExplicitCreateInfoEXT{
		sType                       = .IMAGE_DRM_FORMAT_MODIFIER_EXPLICIT_CREATE_INFO_EXT,
		pNext                       = &ext_img,
		drmFormatModifier           = buf.modifier,
		drmFormatModifierPlaneCount = 1,
		pPlaneLayouts               = &plane,
	}
	info := vk.ImageCreateInfo{
		sType         = .IMAGE_CREATE_INFO,
		pNext         = &mod_img,
		imageType     = .D2,
		format        = format,
		extent        = {buf.width, buf.height, 1},
		mipLevels     = 1,
		arrayLayers   = 1,
		samples       = {._1},
		tiling        = .DRM_FORMAT_MODIFIER_EXT,
		usage         = {.SAMPLED}, // sampled only: the producer writes it
		sharingMode   = .EXCLUSIVE,
		initialLayout = .UNDEFINED,
	}
	if res := vk.CreateImage(r.device, &info, nil, &ps.image); res != .SUCCESS {
		dmabuf_refuse(r, "vkCreateImage(%d x %d, modifier %#x): %v", buf.width, buf.height, buf.modifier, res)
		ps^ = {}
		return 0
	}

	// Our own descriptor for the buffer, so the caller keeps theirs.
	// vkAllocateMemory takes this one over when it succeeds, and only then.
	dup, errno := linux.dup(linux.Fd(buf.fd))
	if errno != .NONE {
		dmabuf_refuse(r, "dup of the buffer's descriptor: %v", errno)
		page_state_destroy(r, ps)
		return 0
	}

	fd_props := vk.MemoryFdPropertiesKHR{sType = .MEMORY_FD_PROPERTIES_KHR}
	if res := vk.GetMemoryFdPropertiesKHR(r.device, {.DMA_BUF_EXT}, c.int(dup), &fd_props); res != .SUCCESS {
		dmabuf_refuse(r, "vkGetMemoryFdPropertiesKHR: %v — is this descriptor a dmabuf from this card?", res)
		linux.close(dup)
		page_state_destroy(r, ps)
		return 0
	}
	req: vk.MemoryRequirements
	vk.GetImageMemoryRequirements(r.device, ps.image, &req)
	// The memory has to suit both the image and the buffer we were handed.
	type_index, found := find_memory_type(r, req.memoryTypeBits & fd_props.memoryTypeBits, {})
	if !found {
		dmabuf_refuse(r, "no memory type suits both the image and the buffer (image %#x, buffer %#x)", req.memoryTypeBits, fd_props.memoryTypeBits)
		linux.close(dup)
		page_state_destroy(r, ps)
		return 0
	}
	// Dedicated: imported memory is one buffer's, never suballocated.
	dedicated := vk.MemoryDedicatedAllocateInfo{sType = .MEMORY_DEDICATED_ALLOCATE_INFO, image = ps.image}
	import_fd := vk.ImportMemoryFdInfoKHR{
		sType      = .IMPORT_MEMORY_FD_INFO_KHR,
		pNext      = &dedicated,
		handleType = {.DMA_BUF_EXT},
		fd         = c.int(dup),
	}
	alloc := vk.MemoryAllocateInfo{
		sType           = .MEMORY_ALLOCATE_INFO,
		pNext           = &import_fd,
		allocationSize  = req.size,
		memoryTypeIndex = type_index,
	}
	if res := vk.AllocateMemory(r.device, &alloc, nil, &ps.memory); res != .SUCCESS {
		dmabuf_refuse(r, "vkAllocateMemory(imported %d bytes): %v", req.size, res)
		linux.close(dup) // ours again: the driver only takes it on success
		page_state_destroy(r, ps)
		return 0
	}
	if res := vk.BindImageMemory(r.device, ps.image, ps.memory, 0); res != .SUCCESS {
		dmabuf_refuse(r, "vkBindImageMemory(imported): %v", res)
		page_state_destroy(r, ps)
		return 0
	}

	vi := vk.ImageViewCreateInfo{
		sType            = .IMAGE_VIEW_CREATE_INFO,
		image            = ps.image,
		viewType         = .D2,
		format           = format,
		subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
	}
	// An X format has no alpha to read: taking it as opaque is what keeps a
	// video frame from being drawn as entirely transparent.
	if is_opaque do vi.components = {r = .IDENTITY, g = .IDENTITY, b = .IDENTITY, a = .ONE}
	if res := vk.CreateImageView(r.device, &vi, nil, &ps.view); res != .SUCCESS {
		dmabuf_refuse(r, "vkCreateImageView(imported): %v", res)
		page_state_destroy(r, ps)
		return 0
	}
	set, pool, ok := desc_set_alloc(r)
	if !ok {
		page_state_destroy(r, ps)
		return 0
	}
	ps.set, ps.pool = set, pool
	// GENERAL, not SHADER_READ_ONLY_OPTIMAL: an imported image stays in the
	// layout a foreign queue hands over and expects back.
	img_info := vk.DescriptorImageInfo{sampler = r.sampler, imageView = ps.view, imageLayout = .GENERAL}
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

// dmabuf_refuse says why an import was refused, once a run. An app that
// cannot import copies its frames in and goes on working, so this is never
// an error, but the copy costs far more CPU and is invisible otherwise.
@(private)
dmabuf_refuse :: proc(r: ^Renderer, msg: string, args: ..any) {
	if r.dmabuf.said do return
	r.dmabuf.said = true
	fmt.eprintf("gpu: a GPU buffer could not be imported, so its frames will be copied instead: ")
	fmt.eprintfln(msg, ..args)
}

// canvas_acquire_fence takes a sync_file the producer's work signals, to be
// waited on before anything samples the buffer again. The descriptor is
// taken over on success and closed on failure: a fence belongs to one frame.
// It is imported as a semaphore, so nothing blocks on the CPU; the next
// submit waits on the GPU's side. False when this device cannot import,
// there is no such page, or the driver refuses the descriptor.
canvas_acquire_fence :: proc(r: ^Renderer, page: Page, sync_fd: int) -> bool {
	if sync_fd < 0 do return false
	if r == nil || r.device == nil {
		dmabuf_drop_fence(sync_fd)
		return false
	}
	ps := page_state(r, page)
	if ps == nil || !ps.imported || !r.dmabuf.caps.import_ok {
		dmabuf_drop_fence(sync_fd)
		return false
	}
	sem, ok := dmabuf_semaphore(r)
	if !ok {
		dmabuf_drop_fence(sync_fd)
		return false
	}
	// TEMPORARY: the payload is this one signal, and the semaphore goes back
	// to having none once it has been waited on — which is what lets the same
	// semaphore serve the next frame.
	imp := vk.ImportSemaphoreFdInfoKHR{
		sType      = .IMPORT_SEMAPHORE_FD_INFO_KHR,
		semaphore  = sem,
		flags      = {.TEMPORARY},
		handleType = {.SYNC_FD},
		fd         = c.int(sync_fd),
	}
	if res := vk.ImportSemaphoreFdKHR(r.device, &imp); res != .SUCCESS {
		dmabuf_refuse(r, "vkImportSemaphoreFdKHR: %v", res)
		dmabuf_drop_fence(sync_fd)
		append(&r.dmabuf.free, sem)
		return false
	}
	append(&r.dmabuf.pending, sem) // the driver has the descriptor now
	return true
}

// dmabuf_drop_fence closes a sync_file nothing will wait on. Every path out
// of canvas_acquire_fence goes through here or hands the descriptor to the
// driver, so "the fence is taken over" holds whatever the answer: the caller
// never closes it.
dmabuf_drop_fence :: proc(sync_fd: int) {
	if sync_fd >= 0 do linux.close(linux.Fd(sync_fd))
}

// dmabuf_semaphore takes a semaphore from the free list, or makes one.
@(private)
dmabuf_semaphore :: proc(r: ^Renderer) -> (vk.Semaphore, bool) {
	if n := len(r.dmabuf.free); n > 0 {
		sem := r.dmabuf.free[n - 1]
		resize(&r.dmabuf.free, n - 1)
		return sem, true
	}
	info := vk.SemaphoreCreateInfo{sType = .SEMAPHORE_CREATE_INFO}
	sem: vk.Semaphore
	if res := vk.CreateSemaphore(r.device, &info, nil, &sem); res != .SUCCESS {
		dmabuf_refuse(r, "vkCreateSemaphore for an acquire fence: %v", res)
		return 0, false
	}
	return sem, true
}

// canvas_import_idle says whether the GPU has finished with an imported
// buffer: true when no frame that sampled it is still running, so the
// producer may draw into it again. True for a page that was never sampled,
// and for anything that is not an imported page. The release half of
// explicit sync: rather than a fence of our own, it answers what a producer
// with a ring of buffers needs before reusing one.
canvas_import_idle :: proc(r: ^Renderer, page: Page) -> bool {
	if r == nil || r.device == nil do return true
	ps := page_state(r, page)
	if ps == nil || !ps.imported || ps.read_serial == 0 do return true
	ts := target_state(r, ps.read_target)
	if ts == nil do return true // the window has gone, and its frames with it
	if int(ps.read_slot) >= len(ts.frames) do return true
	f := &ts.frames[ps.read_slot]
	// A slot is only reused after its fence has been waited on, so a serial
	// that has moved on is itself the answer.
	if f.serial != ps.read_serial do return true
	return vk.GetFenceStatus(r.device, f.fence) == .SUCCESS
}

// dmabuf_frame_begin hands the imported pages this frame will sample over
// from the foreign queue that wrote them, and notes which frame is reading
// them (for canvas_import_idle). Called with the frame's command buffer open,
// before any drawing.
@(private)
dmabuf_frame_begin :: proc(r: ^Renderer, cb: vk.CommandBuffer, t: Target, slot: u32, serial: u64) {
	for b in r.batches {
		ps := page_state(r, b.page)
		if ps == nil || !ps.imported do continue
		if ps.read_serial == serial && ps.read_target == t && u32(ps.read_slot) == slot do continue // already done this frame
		ps.read_serial, ps.read_target, ps.read_slot = serial, t, u8(slot)
		dmabuf_barrier(cb, ps.image, QUEUE_FAMILY_FOREIGN, r.qfamily, {}, {.SHADER_READ},
			{.TOP_OF_PIPE}, {.FRAGMENT_SHADER})
	}
}

// dmabuf_frame_end gives them back, so the producer's next write to the
// buffer is ordered after this frame's reading of it. Called after the last
// draw, before the command buffer ends.
@(private)
dmabuf_frame_end :: proc(r: ^Renderer, cb: vk.CommandBuffer, t: Target, slot: u32, serial: u64) {
	for b in r.batches {
		ps := page_state(r, b.page)
		if ps == nil || !ps.imported do continue
		if ps.read_serial != serial || ps.read_target != t || u32(ps.read_slot) != slot do continue
		if ps.released_serial == serial do continue // once a frame, however many batches read it
		ps.released_serial = serial
		dmabuf_barrier(cb, ps.image, r.qfamily, QUEUE_FAMILY_FOREIGN, {.SHADER_READ}, {},
			{.FRAGMENT_SHADER}, {.BOTTOM_OF_PIPE})
	}
}

// dmabuf_barrier moves queue-family ownership of an imported image, leaving
// it in GENERAL both times: the layout is not ours to change, since the other
// API has no idea what a Vulkan image layout is.
@(private)
dmabuf_barrier :: proc(cb: vk.CommandBuffer, image: vk.Image, from, to: u32,
	src_access, dst_access: vk.AccessFlags, src_stage, dst_stage: vk.PipelineStageFlags) {
	b := vk.ImageMemoryBarrier{
		sType               = .IMAGE_MEMORY_BARRIER,
		srcAccessMask       = src_access,
		dstAccessMask       = dst_access,
		oldLayout           = .GENERAL,
		newLayout           = .GENERAL,
		srcQueueFamilyIndex = from,
		dstQueueFamilyIndex = to,
		image               = image,
		subresourceRange    = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
	}
	vk.CmdPipelineBarrier(cb, src_stage, dst_stage, {}, 0, nil, 0, nil, 1, &b)
}

// dmabuf_waits is the acquire fences the next submit must wait on, and how
// many; they are moved onto the frame, which hands the semaphores back when
// it finishes. Every pending fence is waited on, sampled this frame or not —
// a producer's signal is not ours to leave hanging, and a wait on a fence
// that has already signalled costs nothing.
@(private)
dmabuf_waits :: proc(r: ^Renderer, frame: ^Frame) -> []vk.Semaphore {
	if len(r.dmabuf.pending) == 0 do return nil
	out := make([]vk.Semaphore, len(r.dmabuf.pending), context.temp_allocator)
	copy(out, r.dmabuf.pending[:])
	for sem in r.dmabuf.pending do append(&frame.sems, sem)
	clear(&r.dmabuf.pending)
	return out
}

// dmabuf_frame_done hands a finished frame's acquire semaphores back to be
// used again (their temporary payloads are spent).
@(private)
dmabuf_frame_done :: proc(r: ^Renderer, frame: ^Frame) {
	for sem in frame.sems do append(&r.dmabuf.free, sem)
	clear(&frame.sems)
}

// dmabuf_shutdown destroys the semaphores (the device is going or being
// rebuilt). The pending ones carry a payload nothing will wait on now, which
// is what a lost device means for a frame in flight.
@(private)
dmabuf_shutdown :: proc(r: ^Renderer) {
	if r.device != nil {
		for sem in r.dmabuf.pending do vk.DestroySemaphore(r.device, sem, nil)
		for sem in r.dmabuf.free do vk.DestroySemaphore(r.device, sem, nil)
	}
	delete(r.dmabuf.pending)
	delete(r.dmabuf.free)
	r.dmabuf.pending, r.dmabuf.free = nil, nil
}
