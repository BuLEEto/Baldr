package main

// A GPU buffer from outside, imported and drawn as a canvas.
//
// There is no second process here — the producer is this spike, using Vulkan
// to do what a video helper does with GBM and GL:
//
//   1. report the card Baldr draws on and the modifiers it can import;
//   2. create an image with one of those modifiers and *export* it as a
//      dmabuf, reading back the modifier the driver chose and the plane's
//      offset and stride;
//   3. fill it (a linear buffer in host-visible memory, so the pattern is
//      written with the processor and no command buffer is needed);
//   4. hand the descriptor to `canvas_import_dmabuf` and draw it;
//   5. signal a semaphore, export it as a sync_file, and hand that to
//      `canvas_acquire_fence` — the frame then waits on the GPU's side.
//
// What it proves is the consumer: modifier images, importing memory from a
// descriptor, the memory-type intersection, the descriptor set, the
// foreign-queue barriers around the frame that samples it, and the acquire
// fence. A real producer in another process is the app's half.
//
//   ./build.sh spike dmabuf_import run
//
// The window shows the imported buffer beside a canvas written the ordinary
// way, so the two can be compared by eye; the log says what was imported and
// whether the GPU had finished with it.

import "core:fmt"
import "core:sys/linux"
import "baldr:baldr"
import "baldr:gpu"
import vk "vendor:vulkan"

W :: 256
H :: 160

State :: struct {
	g:        baldr.Gpu,
	imported: baldr.Canvas,
	ours:     baldr.Canvas,
	note:     string,
	fences:   int,
	ticks:    int,
	lost_said: bool,
	ready:    bool,
	// What the *producer* half owns, kept so it can be given back: the image
	// the dmabuf was exported from, its memory, and the semaphore the fence
	// was signalled on. A producer in another process owns exactly these, and
	// all three must be destroyed before the device is.
	prod_image:  vk.Image,
	prod_memory: vk.DeviceMemory,
	fence_sem:   vk.Semaphore,
}

Msg :: union { baldr.Gpu, Tick }

Tick :: struct {}

update :: proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) {
	switch v in m {
	case baldr.Gpu:
		s.g = v
		report(s)
		return baldr.delay(Msg, 200, Tick{})
	case Tick:
		_ = v
		s.ticks += 1
		if s.imported != 0 {
			// A reset takes every canvas with the device, imported ones
			// included: the handle stops being valid and the app
			// imports the producer's buffers again. Run this spike with
			// BALDR_SIMULATE_GPU_RESET=3000 to watch it happen.
			if !baldr.canvas_valid(s.g, s.imported) {
				if !s.lost_said {
					s.lost_said = true
					fmt.eprintfln("dmabuf_import: the device went and took the imported buffer with it (tick %d)", s.ticks)
				}
			} else {
				fmt.eprintfln("dmabuf_import: tick %d: the GPU has %s with the buffer", s.ticks,
					"finished" if baldr.canvas_import_idle(s.g, s.imported) else "not finished")
			}
		}
		if s.ticks >= 12 {
			producer_free(s) // before the runtime tears the device down
			return baldr.quit(Msg)
		}
		return baldr.delay(Msg, 500, Tick{})
	}
	return {}
}

// report says what this card can do, makes the buffer and imports it.
report :: proc(s: ^State) {
	card := baldr.gpu_card(s.g)
	fmt.eprintfln("dmabuf_import: card shares=%v known=%v node=%q (%d:%d)", card.shares, card.known, card.node, card.major, card.minor)

	names := [4]string{"XBGR8888", "ABGR8888", "XRGB8888", "ARGB8888"}
	fourccs := [4]u32{baldr.DRM_FORMAT_XBGR8888, baldr.DRM_FORMAT_ABGR8888, baldr.DRM_FORMAT_XRGB8888, baldr.DRM_FORMAT_ARGB8888}
	mods: [32]u64
	for cc, i in fourccs {
		n := baldr.canvas_import_modifiers(s.g, cc, mods[:])
		fmt.eprintf("dmabuf_import: %s can be imported with %d modifier(s):", names[i], n)
		for k in 0 ..< min(n, len(mods)) do fmt.eprintf(" %#x", mods[k])
		fmt.eprintln()
	}
	// The one every device has, and the one this spike can fill with the
	// processor: a plain row-after-row buffer.
	n := baldr.canvas_import_modifiers(s.g, baldr.DRM_FORMAT_XBGR8888, mods[:])
	if n == 0 {
		s.note = "nothing can be imported on this device"
		fmt.eprintfln("dmabuf_import: %s — an app would copy its frames in instead", s.note)
		return
	}

	buf, image, memory, ok := produce(s.g, W, H)
	if !ok {
		s.note = "the buffer could not be exported (see the log)"
		return
	}
	s.prod_image, s.prod_memory = image, memory
	defer linux.close(linux.Fd(buf.fd)) // ours: Baldr duplicated it
	fmt.eprintfln("dmabuf_import: made a buffer %d x %d fourcc=%08x modifier=%#x offset=%d stride=%d",
		buf.width, buf.height, buf.fourcc, buf.modifier, buf.offset, buf.stride)

	s.imported, ok = baldr.canvas_import_dmabuf(s.g, buf)
	if !ok {
		s.note = "the buffer was refused (see the log)"
		return
	}
	fmt.eprintfln("dmabuf_import: imported as canvas %d; imported=%v writable=%v",
		s.imported, baldr.canvas_imported(s.g, s.imported),
		baldr.canvas_fill(s.g, s.imported, 0, 0, 4, 4, {1, 0, 0, 1}))

	// A fence of our own, to prove the acquire path: a semaphore signalled by
	// an empty submit, exported as a sync_file.
	if fd, got := fence(s); got {
		taken := baldr.canvas_acquire_fence(s.g, s.imported, fd)
		s.fences += 1 if taken else 0
		fmt.eprintfln("dmabuf_import: an acquire fence was %s", "taken" if taken else "refused")
	}

	// …and a canvas of our own with the same pattern, for the eye to compare.
	s.ours, _ = baldr.canvas_create(s.g, {W, H})
	if px, open := baldr.canvas_write_begin(s.g, s.ours, 0, 0, W, H); open {
		pattern(px, W, H, int(W * 4))
		baldr.canvas_write_end(s.g, s.ours)
	}
	s.ready = true
}

// pattern is what the producer "decodes": a gradient with a grid, so a wrong
// stride shears it and a wrong channel order recolours it.
pattern :: proc(px: []u8, w, h, stride: int) {
	for y in 0 ..< h {
		for x in 0 ..< w {
			p := px[y * stride + x * 4:]
			grid := (x / 16 + y / 16) % 2 == 0
			p[0] = u8(x * 255 / (w - 1))
			p[1] = u8(y * 255 / (h - 1))
			p[2] = 200 if grid else 40
			p[3] = 255
		}
	}
}

// producer_free gives back what the producer made. A producer in another
// process does this when it stops sending frames; here, skipping it leaves
// the validation layer reporting undestroyed objects at device teardown.
//
// Order matters: nothing may be reading the buffer, so the device is waited
// on and the imported canvas dropped before the image it was made from goes.
producer_free :: proc(s: ^State) {
	r := baldr.gpu_renderer(s.g)
	if r == nil || r.device == nil do return
	vk.DeviceWaitIdle(r.device)
	if s.imported != 0 {
		baldr.canvas_destroy(s.g, s.imported)
		s.imported = 0
	}
	if s.fence_sem != 0 {
		vk.DestroySemaphore(r.device, s.fence_sem, nil)
		s.fence_sem = 0
	}
	if s.prod_image != 0 {
		vk.DestroyImage(r.device, s.prod_image, nil)
		s.prod_image = 0
	}
	if s.prod_memory != 0 {
		vk.FreeMemory(r.device, s.prod_memory, nil)
		s.prod_memory = 0
	}
}

// produce makes an image with an importable modifier, exports it as a dmabuf
// and fills it. The memory is host-visible so the pattern can be written
// here; a real producer draws into it on the GPU instead. The image and its
// memory come back with the descriptor: they are the producer's to free
// (producer_free), and the fd is only a handle to them.
produce :: proc(g: baldr.Gpu, w, h: u32) -> (out: gpu.Dmabuf, out_image: vk.Image, out_memory: vk.DeviceMemory, ok: bool) {
	r := baldr.gpu_renderer(g)
	if r == nil do return {}, 0, 0, false

	mods: [32]u64
	n := baldr.canvas_import_modifiers(g, baldr.DRM_FORMAT_XBGR8888, mods[:])
	if n == 0 do return {}, 0, 0, false
	// LINEAR if it is importable, since this spike fills the buffer itself.
	chosen := []u64{baldr.DRM_FORMAT_MOD_LINEAR}
	linear := false
	for k in 0 ..< min(n, len(mods)) do if mods[k] == baldr.DRM_FORMAT_MOD_LINEAR do linear = true
	if !linear {
		fmt.eprintfln("dmabuf_import: this device cannot import a linear buffer, which is the only kind this spike can fill")
		return {}, 0, 0, false
	}

	mod_list := vk.ImageDrmFormatModifierListCreateInfoEXT{
		sType                   = .IMAGE_DRM_FORMAT_MODIFIER_LIST_CREATE_INFO_EXT,
		drmFormatModifierCount  = u32(len(chosen)),
		pDrmFormatModifiers     = raw_data(chosen),
	}
	ext := vk.ExternalMemoryImageCreateInfo{
		sType       = .EXTERNAL_MEMORY_IMAGE_CREATE_INFO,
		pNext       = &mod_list,
		handleTypes = {.DMA_BUF_EXT},
	}
	info := vk.ImageCreateInfo{
		sType         = .IMAGE_CREATE_INFO,
		pNext         = &ext,
		imageType     = .D2,
		format        = .R8G8B8A8_UNORM,
		extent        = {w, h, 1},
		mipLevels     = 1,
		arrayLayers   = 1,
		samples       = {._1},
		tiling        = .DRM_FORMAT_MODIFIER_EXT,
		usage         = {.SAMPLED},
		sharingMode   = .EXCLUSIVE,
		initialLayout = .UNDEFINED,
	}
	image: vk.Image
	if res := vk.CreateImage(r.device, &info, nil, &image); res != .SUCCESS {
		fmt.eprintfln("dmabuf_import: vkCreateImage (the producer's): %v", res)
		return {}, 0, 0, false
	}
	defer if !ok do vk.DestroyImage(r.device, image, nil)

	req: vk.MemoryRequirements
	vk.GetImageMemoryRequirements(r.device, image, &req)
	type_index, found := memory_type(r, req.memoryTypeBits, {.HOST_VISIBLE, .HOST_COHERENT})
	if !found {
		fmt.eprintfln("dmabuf_import: no host-visible memory suits an exported image, so this spike cannot fill one")
		return {}, 0, 0, false
	}
	export := vk.ExportMemoryAllocateInfo{sType = .EXPORT_MEMORY_ALLOCATE_INFO, handleTypes = {.DMA_BUF_EXT}}
	dedicated := vk.MemoryDedicatedAllocateInfo{sType = .MEMORY_DEDICATED_ALLOCATE_INFO, pNext = &export, image = image}
	alloc := vk.MemoryAllocateInfo{
		sType           = .MEMORY_ALLOCATE_INFO,
		pNext           = &dedicated,
		allocationSize  = req.size,
		memoryTypeIndex = type_index,
	}
	memory: vk.DeviceMemory
	if res := vk.AllocateMemory(r.device, &alloc, nil, &memory); res != .SUCCESS {
		fmt.eprintfln("dmabuf_import: vkAllocateMemory (exported): %v", res)
		return {}, 0, 0, false
	}
	defer if !ok do vk.FreeMemory(r.device, memory, nil)
	if res := vk.BindImageMemory(r.device, image, memory, 0); res != .SUCCESS {
		fmt.eprintfln("dmabuf_import: vkBindImageMemory (exported): %v", res)
		return {}, 0, 0, false
	}

	// What the driver actually chose, and where the plane sits in the memory.
	props := vk.ImageDrmFormatModifierPropertiesEXT{sType = .IMAGE_DRM_FORMAT_MODIFIER_PROPERTIES_EXT}
	if res := vk.GetImageDrmFormatModifierPropertiesEXT(r.device, image, &props); res != .SUCCESS {
		fmt.eprintfln("dmabuf_import: vkGetImageDrmFormatModifierPropertiesEXT: %v", res)
		return {}, 0, 0, false
	}
	sub := vk.ImageSubresource{aspectMask = {.MEMORY_PLANE_0_EXT}}
	layout: vk.SubresourceLayout
	vk.GetImageSubresourceLayout(r.device, image, &sub, &layout)

	// Fill it where it lies.
	mapped: rawptr
	if res := vk.MapMemory(r.device, memory, 0, vk.DeviceSize(vk.WHOLE_SIZE), {}, &mapped); res != .SUCCESS {
		fmt.eprintfln("dmabuf_import: vkMapMemory (exported): %v", res)
		return {}, 0, 0, false
	}
	bytes := ([^]u8)(mapped)[:req.size]
	pattern(bytes[layout.offset:], int(w), int(h), int(layout.rowPitch))
	vk.UnmapMemory(r.device, memory)

	get := vk.MemoryGetFdInfoKHR{sType = .MEMORY_GET_FD_INFO_KHR, memory = memory, handleType = {.DMA_BUF_EXT}}
	fd: i32
	if res := vk.GetMemoryFdKHR(r.device, &get, &fd); res != .SUCCESS {
		fmt.eprintfln("dmabuf_import: vkGetMemoryFdKHR: %v", res)
		return {}, 0, 0, false
	}
	// The image and memory stay alive for the run: this stands in for another
	// process holding its own buffer, which is the whole point of the fd.
	return gpu.Dmabuf{
		fd = int(fd), width = w, height = h,
		fourcc = baldr.DRM_FORMAT_XBGR8888, modifier = props.drmFormatModifier,
		offset = u32(layout.offset), stride = u32(layout.rowPitch),
	}, image, memory, true
}

// fence signals a semaphore with an empty submit and exports it as a
// sync_file, which is what a producer hands over with each frame.
//
// The semaphore outlives the call: the spec wants every batch referring to
// a semaphore finished before it is destroyed, so a producer keeps its
// semaphores and lets them go when it stops (producer_free). Exporting a
// SYNC_FD moves the payload out, so the same semaphore serves the next frame.
fence :: proc(s: ^State) -> (int, bool) {
	r := baldr.gpu_renderer(s.g)
	if r == nil do return -1, false
	if s.fence_sem == 0 {
		export := vk.ExportSemaphoreCreateInfo{sType = .EXPORT_SEMAPHORE_CREATE_INFO, handleTypes = {.SYNC_FD}}
		info := vk.SemaphoreCreateInfo{sType = .SEMAPHORE_CREATE_INFO, pNext = &export}
		sem: vk.Semaphore
		if res := vk.CreateSemaphore(r.device, &info, nil, &sem); res != .SUCCESS {
			fmt.eprintfln("dmabuf_import: vkCreateSemaphore (exportable): %v", res)
			return -1, false
		}
		s.fence_sem = sem
	}
	sem := s.fence_sem
	submit := vk.SubmitInfo{sType = .SUBMIT_INFO, signalSemaphoreCount = 1, pSignalSemaphores = &sem}
	if res := vk.QueueSubmit(r.queue, 1, &submit, 0); res != .SUCCESS {
		fmt.eprintfln("dmabuf_import: vkQueueSubmit (signalling the fence): %v", res)
		return -1, false
	}
	get := vk.SemaphoreGetFdInfoKHR{sType = .SEMAPHORE_GET_FD_INFO_KHR, semaphore = sem, handleType = {.SYNC_FD}}
	fd: i32 = -1
	if res := vk.GetSemaphoreFdKHR(r.device, &get, &fd); res != .SUCCESS {
		fmt.eprintfln("dmabuf_import: vkGetSemaphoreFdKHR: %v", res)
		return -1, false
	}
	// -1 is legal and means "already signalled, nothing to wait for".
	return int(fd), fd >= 0
}

// memory_type is find_memory_type's job, done here because the renderer's is
// its own business.
memory_type :: proc(r: ^gpu.Renderer, bits: u32, want: vk.MemoryPropertyFlags) -> (u32, bool) {
	props: vk.PhysicalDeviceMemoryProperties
	vk.GetPhysicalDeviceMemoryProperties(r.phys, &props)
	for i in 0 ..< props.memoryTypeCount {
		if bits & (1 << i) == 0 do continue
		if props.memoryTypes[i].propertyFlags >= want do return i, true
	}
	return 0, false
}

view :: proc(s: ^State, ui: ^baldr.Ui(Msg)) {
	baldr.column(ui, flex = 1, padding = .md, gap = .sm); defer baldr.end(ui)
	if s.note != "" do baldr.text(ui, s.note, role = .Caption)
	if !s.ready do return
	baldr.row(ui, gap = .md, flex = 1); defer baldr.end(ui)
	{
		baldr.column(ui, gap = .xs, key = 1); defer baldr.end(ui)
		baldr.text(ui, "imported from a descriptor", role = .Caption)
		baldr.canvas(ui, s.g, s.imported, width = W, label = "the imported buffer")
	}
	{
		baldr.column(ui, gap = .xs, key = 2); defer baldr.end(ui)
		baldr.text(ui, "written the ordinary way", role = .Caption)
		baldr.canvas(ui, s.g, s.ours, width = W, label = "a canvas of our own")
	}
}

main :: proc() {
	baldr.run(baldr.App(State, Msg){
		title = "Imported buffer", app_id = "dev.baldr.dmabuf_import", size = {2 * W + 60, H + 110},
		init = proc() -> (s: State) { return },
		start = proc(s: ^State) -> baldr.Cmd(Msg) { return baldr.gpu_open(Msg, proc(e: baldr.Ev(baldr.Gpu)) -> Msg { return e.value }) },
		update = update,
		view = view,
	})
}
