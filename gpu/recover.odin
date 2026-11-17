#+build !darwin
package gpu

// Surviving a GPU reset.
//
// A card is reset for many reasons — a driver bug, a hung shader in another
// program — and every client on it is told its device is gone. The device is
// then made again: the instance, the loader and the surfaces survive;
// everything the device owned is built afresh, and the targets keep their
// handles so an app's `Target` stays valid. Uploaded glyphs, pictures and
// images are gone, and the layer above re-uploads them from its CPU copies.
// Canvases have no CPU copy by design, so the app is told they are gone.

import vk "vendor:vulkan"

// lost says the device has gone. It stays true until `recover` succeeds.
lost :: proc "contextless" (r: ^Renderer) -> bool {
	return r != nil && r.lost
}

// mark_lost records that the device has gone, once. Every path that sees
// ERROR_DEVICE_LOST calls it, and only the first logs, so a reset is one
// line rather than one a frame.
@(private)
mark_lost :: proc(r: ^Renderer) {
	if r == nil || r.lost do return
	r.lost = true
	r.lost_logged = false // a fresh loss: the layer above says so once more
	r.recoveries_failed = 0
}

// lost_first says whether this is the first report of the current loss, so
// the layer above logs one line rather than one a frame. It answers true
// once per loss — a reset, or a surface going — and false after.
lost_first :: proc "contextless" (r: ^Renderer) -> bool {
	if r == nil || r.lost_logged do return false
	r.lost_logged = true
	return true
}

// simulate_device_lost makes the renderer believe its device has gone, so
// the recovery path can be exercised without a real reset. Safe on any
// device, including a software one: nothing is faulted, it is just rebuilt.
simulate_device_lost :: proc(r: ^Renderer) {
	mark_lost(r)
}

// recover rebuilds the device and everything under it after a reset. The
// surfaces are kept (they belong to the instance) and each target is made
// again in its own slot, so handles the app holds stay good. False means
// the card is not ready yet — the caller waits and asks again rather than
// spinning.
//
// Everything that was on the device is gone afterwards: pages, atlases,
// canvases, pipelines. Whoever put them there puts them there again.
recover :: proc(r: ^Renderer) -> bool {
	if r == nil || r.inst == nil do return false

	// what the targets were, so they can be what they were again
	Saved :: struct {
		used:        bool,
		surface:     vk.SurfaceKHR,
		size_px:     [2]u32,
		transparent: bool,
	}
	saved: [MAX_TARGETS]Saved
	for &t, i in r.targets {
		if !t.used do continue
		saved[i] = {used = true, surface = t.surface, size_px = t.size_px, transparent = t.transparent}
		t.surface = 0 // the instance's: it must outlive the device's teardown
	}

	device_teardown(r)

	first := vk.SurfaceKHR(0)
	for s in saved do if s.used && s.surface != 0 { first = s.surface; break }
	if first == 0 {
		// No surface to make a device for. Not a failure: the app has no
		// window at the moment, and the next target_add makes one.
		r.lost, r.lost_logged = false, false
		return true
	}
	if !device_create(r, first) {
		// The slots were emptied for the teardown; give them their surfaces
		// back, or the next attempt has no windows to rebuild and the app
		// goes on naming targets nothing holds.
		for s, i in saved do if s.used {
			r.targets[i] = {used = true, surface = s.surface, size_px = s.size_px, transparent = s.transparent, lost = true}
		}
		r.recoveries_failed += 1
		return false
	}
	failed := false
	for s, i in saved {
		if !s.used do continue
		// Every slot is tried, even after one has failed: target_restore
		// leaves a failed one holding its surface, and stopping would leave
		// the ones after it with nowhere to come back to.
		if !target_restore(r, i, s.surface, s.size_px, s.transparent) do failed = true
	}
	if failed {
		r.recoveries_failed += 1
		return false
	}
	r.lost, r.lost_logged = false, false
	r.recoveries_failed = 0
	r.generation += 1 // what the layer above uploaded is gone: this says so
	return true
}

// recoveries_failed is how many attempts in a row have not brought the
// device back. An app that cannot recover should stop rather than spin.
recoveries_failed :: proc "contextless" (r: ^Renderer) -> int {
	return r.recoveries_failed if r != nil else 0
}

// generation counts how many times the device has been rebuilt. Anything
// holding a Page from before is holding nothing.
generation :: proc "contextless" (r: ^Renderer) -> u64 {
	return r.generation if r != nil else 0
}

// device_teardown destroys everything the device owned, and the device, but
// keeps the instance, the loader and the surfaces. It is `destroy` without
// its last two steps, and is used by nothing else: a reset is the only time
// a device goes while its app keeps running.
@(private)
device_teardown :: proc(r: ^Renderer) {
	if r.device == nil do return
	// Wait first, and ignore what it says. A device really lost returns the
	// loss at once; one merely being rebuilt (a test, a driver that recovered
	// itself) has work in flight, and tearing it down under that crashes in
	// the driver's own threads.
	vk.DeviceWaitIdle(r.device)
	canvas_shutdown(r)
	dmabuf_shutdown(r)
	for &t in r.targets {
		if !t.used do continue
		surface := t.surface
		t.surface = 0 // kept: the instance owns it
		target_state_destroy(r, &t)
		t.surface = surface
		t.used = false
	}
	for &p in r.pages do if p.used { page_state_destroy(r, &p) }
	for &u in r.uploads { buffer_destroy(r, &u.staging) }
	clear(&r.uploads)
	for e in r.pipelines { vk.DestroyPipeline(r.device, e.pipeline, nil) }
	clear(&r.pipelines)
	if r.pipeline_layout != 0 { vk.DestroyPipelineLayout(r.device, r.pipeline_layout, nil) }
	if r.blur_pipeline != 0 { vk.DestroyPipeline(r.device, r.blur_pipeline, nil) }
	if r.blur_layout != 0 { vk.DestroyPipelineLayout(r.device, r.blur_layout, nil) }
	for e in r.present_pipelines { vk.DestroyPipeline(r.device, e.pipeline, nil) }
	clear(&r.present_pipelines)
	if r.present_layout != 0 { vk.DestroyPipelineLayout(r.device, r.present_layout, nil) }
	if r.sampler != 0 { vk.DestroySampler(r.device, r.sampler, nil) }
	if r.mip_sampler != 0 { vk.DestroySampler(r.device, r.mip_sampler, nil) }
	if r.nearest_sampler != 0 { vk.DestroySampler(r.device, r.nearest_sampler, nil) }
	for pool in r.desc_pools { vk.DestroyDescriptorPool(r.device, pool, nil) }
	clear(&r.desc_pools)
	if r.desc_layout != 0 { vk.DestroyDescriptorSetLayout(r.device, r.desc_layout, nil) }
	if r.cmd_pool != 0 { vk.DestroyCommandPool(r.device, r.cmd_pool, nil) }
	vk.DestroyDevice(r.device, nil)

	// every device-level handle the renderer held is now a dangling number
	r.device = nil
	r.queue = nil
	r.cmd_pool = 0
	r.desc_layout = 0
	r.pipeline_layout = 0
	r.blur_pipeline, r.blur_layout = 0, 0
	r.present_layout = 0
	r.sampler, r.mip_sampler, r.nearest_sampler = 0, 0, 0
	r.blend_pipelines, r.blend_layout = {}, 0
	r.transform_pipelines, r.transform_layout = {}, 0
	r.filter_pipelines, r.filter_layout = {}, 0
	r.dab_pipelines, r.dab_layout = {}, 0
	r.stroke_pipelines, r.stroke_layout = {}, 0
	// …and so is every page number it kept. The slots are free now and the
	// next page created takes one: a scratch id held from before would name
	// a glyph atlas, and the blend that asked for it would draw into it.
	r.canvas_scratch = {}
	r.cur_blur_set = 0
}
