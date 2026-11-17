#+build darwin
// metal.odin — the Metal half of gpu, for macOS.
//
// batch.odin turns draw commands into vertices and batches with no device in
// sight; this records and presents them through Metal: the device, targets
// on a CAMetalLayer, the glyph and picture atlas, render(), the blur chain
// and device-loss recovery. macOS gets a native renderer rather than
// MoltenVK, and the shaders are ui.vert and ui.frag ported line for line,
// not paraphrased. Canvases and an app's own shaders are in
// metal_canvas.odin and metal_shader.odin.
package gpu

import CA "vendor:darwin/QuartzCore"
import MTL "vendor:darwin/Metal"
import NS "core:sys/darwin/Foundation"
import "core:mem"

MAX_PAGES :: 256

// Buffer is a GPU buffer the caller holds (canvas strokes). Metal's is one
// object, where Vulkan's needs memory beside it. `ptr` is its contents,
// which canvas_queue.odin writes the dab and stroke quads straight into.
Buffer :: struct {
	buf:  ^MTL.Buffer,
	size: int,
	ptr:  rawptr,
	use:  Buffer_Use, // what it was made for, so a returned one finds its pool (canvas_staging.odin)
}

// Page_State is one atlas page or picture. `format` is the field batch.odin
// reads to choose between the alpha and RGBA glyph kinds; the rest is ours.
Page_State :: struct {
	used:   bool,
	format: Page_Format,
	size:   [2]u32,
	tex:    ^MTL.Texture,
	// How many mip levels the texture has: 1 for an atlas, the full chain
	// for a canvas that is filtered and asked for them.
	levels: u32,
	// batch.odin reads `canvas` and `space` to mark an Image drawn from a
	// canvas and the colour space to decode it from; metal_canvas.odin reads
	// `canvas_format` for the texel layout and the pipeline's attachment.
	canvas:        bool,
	canvas_format: Canvas_Format,
	space:         Color_Space,
	// Always false here: importing another process's GPU buffer is a Linux
	// mechanism (dmabuf), but canvas_queue.odin, which both backends share,
	// asks it to decide whether a canvas may be written to.
	imported:      bool,
}

@(private)
Target_State :: struct {
	used:    bool,
	layer:   ^CA.MetalLayer,
	size_px: [2]u32,
}

// Renderer is the device and everything hanging off it. Its first fields are
// the ones batch.odin uses, and they are the same on both backends.
Renderer :: struct {
	// ---- shared with batch.odin
	verts:      [dynamic]Vertex,
	batches:    [dynamic]Batch,
	clips:      [dynamic][4]f32,
	last_error: string,
	target_fault: Target_Fault,

	// ---- Metal
	dev:      ^MTL.Device,
	queue:    ^MTL.CommandQueue,
	pipeline: ^MTL.RenderPipelineState,
	sampler:  ^MTL.SamplerState,
	white:    Page, // the 1x1 page a quad samples, as WHITE_PAGE on Vulkan
	pages:    [MAX_PAGES]Page_State,
	targets:  [MAX_TARGETS]Target_State,
	vbuf:     ^MTL.Buffer,
	vbuf_cap: int,

	// frosted glass
	blur_pipeline: ^MTL.RenderPipelineState,
	copy_pipeline: ^MTL.RenderPipelineState,
	blur:          Blur_State,
	blur_tex:      ^MTL.Texture, // the scene blurred, for this frame's Backdrops

	// canvases (metal_canvas.odin) and an app's own shaders (metal_shader.odin)
	canvas_ops:        [dynamic]Canvas_Op,
	canvas_batches:    [dynamic]^Canvas_Batch,
	staging:           Staging, // staging buffers kept to be used again (canvas_staging.odin)
	writing:           bool,    // a canvas_write_begin is open (canvas_queue.odin)
	writing_said:      bool,    // …and one was left open: said once, not once a frame
	canvas_next_read:  u32,
	canvas_next_batch: u64,
	canvas_scratch:    [2][Canvas_Format]Page,
	canvas_formats:    bit_set[Canvas_Format],
	canvas_filtered:   bit_set[Canvas_Format],
	canvas_storage:    bit_set[Canvas_Format],
	canvas_memory:     u64,
	canvas_lib:        ^MTL.Library,
	canvas_pipelines:  [Canvas_Pass][Canvas_Format]^MTL.RenderPipelineState,
	shaders:           [dynamic]Shader_State,

	// A canvas is sampled by its own format's rules: nearest where the device
	// will not filter it (32-bit float on Apple silicon), and through the mip
	// chain where it has one.
	nearest_sampler: ^MTL.SamplerState,
	mip_sampler:     ^MTL.SamplerState,

	// Named as the Vulkan half names them, because baldr/gpu_reset_test.odin
	// drives a reset through these fields directly.
	lost:        bool,
	lost_logged: bool,
	generation:  u64,
	fails:       int,
}

@(private)
SHADER_SRC :: #load("shaders/ui.metal", string)

@(private)
BLUR_SRC :: #load("shaders/blur.metal", string)

// ------------------------------------------------------------------ device

init :: proc(r: ^Renderer, instance_exts: []cstring, app_name: cstring) -> (ok: bool, why: string) {
	r.dev = MTL.CreateSystemDefaultDevice()
	if r.dev == nil do return false, "no Metal device"
	r.queue = r.dev->newCommandQueue()
	if r.queue == nil do return false, "no Metal command queue"

	src := NS.String.alloc()->initWithOdinString(SHADER_SRC)
	opts := MTL.CompileOptions.alloc()->init()
	defer opts->release()
	lib, lib_err := r.dev->newLibraryWithSource(src, opts)
	if lib == nil {
		return false, lib_err != nil ? string(lib_err->localizedDescription()->odinString()) : "ui.metal did not compile"
	}
	defer lib->release()
	v_fn := lib->newFunctionWithName(NS.AT("v_main"))
	f_fn := lib->newFunctionWithName(NS.AT("f_main"))
	if v_fn == nil || f_fn == nil do return false, "ui.metal has no v_main/f_main"
	defer v_fn->release()
	defer f_fn->release()

	desc := MTL.RenderPipelineDescriptor.alloc()->init()
	defer desc->release()
	desc->setVertexFunction(v_fn)
	desc->setFragmentFunction(f_fn)
	att := desc->colorAttachments()->object(0)
	// sRGB, not Unorm: Baldr's colours are linear, so the hardware must encode
	// linear->sRGB on write and blend in linear light, as the Vulkan path's
	// B8G8R8A8_SRGB swapchain does. A Unorm surface darkens every mid-tone and
	// blends glyph coverage in the wrong space.
	att->setPixelFormat(.BGRA8Unorm_sRGB)
	// Straight alpha over the target, the same state the Vulkan pipeline uses.
	att->setBlendingEnabled(true)
	att->setSourceRGBBlendFactor(.SourceAlpha)
	att->setDestinationRGBBlendFactor(.OneMinusSourceAlpha)
	att->setSourceAlphaBlendFactor(.One)
	att->setDestinationAlphaBlendFactor(.OneMinusSourceAlpha)
	pipe, pipe_err := r.dev->newRenderPipelineStateWithDescriptor(desc)
	if pipe == nil {
		return false, pipe_err != nil ? string(pipe_err->localizedDescription()->odinString()) : "pipeline"
	}
	r.pipeline = pipe

	// the blur chain's two full-screen pipelines
	blur_src := NS.String.alloc()->initWithOdinString(BLUR_SRC)
	blib, blib_err := r.dev->newLibraryWithSource(blur_src, opts)
	if blib == nil {
		return false, blib_err != nil ? string(blib_err->localizedDescription()->odinString()) : "blur.metal did not compile"
	}
	defer blib->release()
	fs_fn := blib->newFunctionWithName(NS.AT("fs_main"))
	kw_fn := blib->newFunctionWithName(NS.AT("kawase_main"))
	cp_fn := blib->newFunctionWithName(NS.AT("copy_main"))
	if fs_fn == nil || kw_fn == nil || cp_fn == nil do return false, "blur.metal has no fs_main/kawase_main/copy_main"
	defer fs_fn->release()
	defer kw_fn->release()
	defer cp_fn->release()
	for spec in ([2]struct{ frag: ^MTL.Function, out: ^^MTL.RenderPipelineState }{
		{kw_fn, &r.blur_pipeline}, {cp_fn, &r.copy_pipeline},
	}) {
		d := MTL.RenderPipelineDescriptor.alloc()->init()
		defer d->release()
		d->setVertexFunction(fs_fn)
		d->setFragmentFunction(spec.frag)
		d->colorAttachments()->object(0)->setPixelFormat(.BGRA8Unorm_sRGB)
		pl, perr := r.dev->newRenderPipelineStateWithDescriptor(d)
		if pl == nil {
			return false, perr != nil ? string(perr->localizedDescription()->odinString()) : "blur pipeline"
		}
		spec.out^ = pl
	}

	sd := MTL.SamplerDescriptor.alloc()->init()
	defer sd->release()
	sd->setMinFilter(.Linear)
	sd->setMagFilter(.Linear)
	r.sampler = r.dev->newSamplerStateWithDescriptor(sd)

	// The same, through the mip chain: what a canvas with smaller levels is
	// drawn with when it is shown reduced.
	md := MTL.SamplerDescriptor.alloc()->init()
	defer md->release()
	md->setMinFilter(.Linear)
	md->setMagFilter(.Linear)
	md->setMipFilter(.Linear)
	r.mip_sampler = r.dev->newSamplerStateWithDescriptor(md)

	// And nearest, for a canvas in a format the device will not filter.
	nd := MTL.SamplerDescriptor.alloc()->init()
	defer nd->release()
	nd->setMinFilter(.Nearest)
	nd->setMagFilter(.Nearest)
	r.nearest_sampler = r.dev->newSamplerStateWithDescriptor(nd)

	canvas_formats_probe(r)

	// The white page: what a quad samples and what an unknown page falls back
	// to, exactly as WHITE_PAGE is on Vulkan.
	r.white = atlas_create(r, .Alpha8, {1, 1})
	if r.white == 0 do return false, "white page"
	ones := [1]u8{255}
	atlas_upload(r, r.white, 0, 0, 1, 1, ones[:])
	return true, ""
}

destroy :: proc(r: ^Renderer) {
	device_teardown(r)
	delete(r.verts)
	delete(r.batches)
	delete(r.clips)
	r^ = {}
}

// instance is Vulkan's; on Metal there is nothing to hand out and nothing
// asks, because the drawable comes from the platform backend instead.
instance :: proc(r: ^Renderer) -> rawptr { return nil }

// ------------------------------------------------------------ device loss
//
// Metal has no VK_ERROR_DEVICE_LOST to poll: a GPU reset surfaces as a
// command buffer that errored, which render() turns into `lost`.

lost :: proc "contextless" (r: ^Renderer) -> bool { return r != nil && r.lost }

// lost_first is true once per loss, as on the Vulkan half, so the layer above
// logs one line rather than one a frame.
lost_first :: proc "contextless" (r: ^Renderer) -> bool {
	if r == nil || r.lost_logged do return false
	r.lost_logged = true
	return true
}

recoveries_failed :: proc "contextless" (r: ^Renderer) -> int { return r != nil ? r.fails : 0 }

// generation counts how many times the device has been rebuilt. Anything
// uploaded under an older one is gone.
generation :: proc "contextless" (r: ^Renderer) -> u64 { return r != nil ? r.generation : 0 }

// recover rebuilds the device after a loss. Pages, atlases, pipelines and the
// blur chain are gone, and `generation` tells their owners to upload again.
// A target's layer is the window's, not the device's, so the layers survive
// and are pointed at the new device.
recover :: proc(r: ^Renderer) -> bool {
	if r == nil || r.dev == nil do return false

	// what the targets were; the layers themselves outlive the device
	Saved :: struct {
		used:    bool,
		layer:   ^CA.MetalLayer,
		size_px: [2]u32,
	}
	saved: [MAX_TARGETS]Saved
	for t, i in r.targets do if t.used do saved[i] = {true, t.layer, t.size_px}

	device_teardown(r)
	ok, _ := init(r, nil, "baldr")
	if !ok {
		r.fails += 1
		return false
	}
	for sv, i in saved {
		if !sv.used || sv.layer == nil do continue
		sv.layer->setDevice(r.dev)
		sv.layer->setDrawableSize({NS.Float(sv.size_px.x), NS.Float(sv.size_px.y)})
		r.targets[i] = {used = true, layer = sv.layer, size_px = sv.size_px}
	}
	r.lost, r.lost_logged = false, false
	r.fails = 0
	r.generation += 1 // what the layer above uploaded is gone: this says so
	return true
}

// device_teardown drops everything the device owns, leaving the Renderer
// re-initialisable. The target *table* is cleared with it; `recover` puts the
// entries back from the layers it saved.
@(private)
device_teardown :: proc(r: ^Renderer) {
	canvas_shutdown(r)
	blur_destroy(r)
	for i in 0 ..< MAX_PAGES do if r.pages[i].used && r.pages[i].tex != nil do r.pages[i].tex->release()
	r.pages = {}
	r.targets = {}
	if r.vbuf != nil { r.vbuf->release(); r.vbuf = nil }
	r.vbuf_cap = 0
	if r.blur_pipeline != nil { r.blur_pipeline->release(); r.blur_pipeline = nil }
	if r.copy_pipeline != nil { r.copy_pipeline->release(); r.copy_pipeline = nil }
	if r.mip_sampler != nil { r.mip_sampler->release(); r.mip_sampler = nil }
	if r.nearest_sampler != nil { r.nearest_sampler->release(); r.nearest_sampler = nil }
	if r.sampler != nil { r.sampler->release(); r.sampler = nil }
	if r.pipeline != nil { r.pipeline->release(); r.pipeline = nil }
	if r.queue != nil { r.queue->release(); r.queue = nil }
	if r.dev != nil { r.dev->release(); r.dev = nil }
	r.white = 0
	r.blur_tex = nil
}

// simulate_device_lost makes the renderer believe its device has gone, so the
// recovery path can be exercised without a real reset.
simulate_device_lost :: proc(r: ^Renderer) { r.lost = true }

// ------------------------------------------------------------------ pages

page_state :: proc(r: ^Renderer, p: Page) -> ^Page_State {
	i := int(p) - 1
	if i < 0 || i >= MAX_PAGES || !r.pages[i].used do return nil
	return &r.pages[i]
}

// page_make makes an atlas or picture page. `mips` is not honoured yet: an
// atlas never wants them and a picture's would have to be generated on a
// command buffer, where atlas_upload writes from the CPU with replaceRegion.
// Canvases, which do want them, go through canvas_make instead.
@(private)
page_make :: proc(r: ^Renderer, format: Page_Format, size: [2]u32, mips: bool) -> Page {
	slot := -1
	for i in 0 ..< MAX_PAGES do if !r.pages[i].used { slot = i; break }
	if slot < 0 do return 0

	td := MTL.TextureDescriptor.alloc()->init()
	defer td->release()
	td->setTextureType(._2D)
	td->setPixelFormat(format == .RGBA8 ? .RGBA8Unorm : .R8Unorm)
	td->setWidth(NS.UInteger(size.x))
	td->setHeight(NS.UInteger(size.y))
	td->setUsage({.ShaderRead})
	tex := r.dev->newTextureWithDescriptor(td)
	if tex == nil do return 0

	r.pages[slot] = {used = true, format = format, size = size, levels = 1, tex = tex}
	return Page(slot + 1)
}

atlas_create :: proc(r: ^Renderer, format: Page_Format, size: [2]u32) -> Page {
	return page_make(r, format, size, false)
}

picture_create :: proc(r: ^Renderer, size: [2]u32) -> Page {
	return page_make(r, .RGBA8, size, true)
}

atlas_upload :: proc(r: ^Renderer, page: Page, x, y, w, h: u32, pixels: []u8) {
	ps := page_state(r, page)
	if ps == nil || ps.tex == nil || w == 0 || h == 0 do return
	bpp := u32(ps.format == .RGBA8 ? 4 : 1)
	if len(pixels) < int(w * h * bpp) do return
	ps.tex->replaceRegion(
		MTL.Region{{NS.UInteger(x), NS.UInteger(y), 0}, {NS.UInteger(w), NS.UInteger(h), 1}},
		0, raw_data(pixels), NS.UInteger(w * bpp))
}

atlas_destroy :: proc(r: ^Renderer, page: Page) {
	ps := page_state(r, page)
	if ps == nil do return
	if ps.tex != nil do ps.tex->release()
	ps^ = {}
}

// ---------------------------------------------------------------- targets

target_add :: proc(r: ^Renderer, drawable: Drawable, size_px: [2]u32, transparent: bool) -> (Target, bool) {
	layer := (^CA.MetalLayer)(uintptr(drawable))
	r.target_fault = .None
	if layer == nil { r.target_fault = .Drawable; return 0, false }
	slot := -1
	for i in 0 ..< MAX_TARGETS do if !r.targets[i].used { slot = i; break }
	if slot < 0 { r.target_fault = .Slots; return 0, false }

	layer->setDevice(r.dev)
	layer->setPixelFormat(.BGRA8Unorm_sRGB) // see the pipeline: linear in, sRGB on the wire
	layer->setFramebufferOnly(true)
	layer->setOpaque(!transparent)
	layer->setDrawableSize({NS.Float(size_px.x), NS.Float(size_px.y)})
	r.targets[slot] = {used = true, layer = layer, size_px = size_px}
	return Target(slot + 1), true
}

@(private)
target_state :: proc(r: ^Renderer, t: Target) -> ^Target_State {
	i := int(t) - 1
	if i < 0 || i >= MAX_TARGETS || !r.targets[i].used do return nil
	return &r.targets[i]
}

target_resize :: proc(r: ^Renderer, t: Target, size_px: [2]u32) {
	ts := target_state(r, t)
	if ts == nil || ts.layer == nil do return
	ts.size_px = size_px
	// Every frame would do, but a resize is when it actually changes, and a
	// stale drawable size silently stretches the frame.
	ts.layer->setDrawableSize({NS.Float(size_px.x), NS.Float(size_px.y)})
}

target_remove :: proc(r: ^Renderer, t: Target) {
	if ts := target_state(r, t); ts != nil do ts^ = {}
}

// target_fault says why the last target_add failed (api.odin).
target_fault :: proc "contextless" (r: ^Renderer) -> Target_Fault {
	return r.target_fault if r != nil else .None
}

// drawable_release does nothing: a CAMetalLayer belongs to the platform
// backend, which lets it go with its window. It exists so the toolkit's
// "the renderer would not take this drawable" path compiles on both backends.
drawable_release :: proc(r: ^Renderer, d: Drawable) {}

// ----------------------------------------------------------------- render

render :: proc(r: ^Renderer, t: Target, cmds: []Cmd, clear: [4]f32, damage: [][4]f32) -> Render_Result {
	ts := target_state(r, t)
	if ts == nil || ts.layer == nil do return .Error
	if ts.size_px.x == 0 || ts.size_px.y == 0 do return .Skipped

	// A pool per frame: Metal hands back autoreleased objects every frame —
	// the drawable, the pass descriptor, the command buffer, the encoder — and
	// without one they accumulate for the life of the process.
	pool := NS.AutoreleasePool.alloc()->init()
	defer pool->drain()

	build_batches(r, cmds, ts.size_px)
	if len(r.verts) == 0 do return .Skipped

	need := len(r.verts) * size_of(Vertex)
	if need > r.vbuf_cap {
		if r.vbuf != nil do r.vbuf->release()
		r.vbuf_cap = max(need * 2, 64 * 1024)
		r.vbuf = r.dev->newBufferWithLength(NS.UInteger(r.vbuf_cap), {})
		if r.vbuf == nil { r.vbuf_cap = 0; return .Error }
	}
	mem.copy(r.vbuf->contents(), raw_data(r.verts), need)

	drawable := ts.layer->nextDrawable()
	// Not released: nextDrawable is autoreleased and the frame pool owns it.
	// Releasing it crashes later, inside objc_autoreleasePoolPop.
	if drawable == nil do return .Skipped

	pass := MTL.RenderPassDescriptor.renderPassDescriptor()
	colour := pass->colorAttachments()->object(0)
	colour->setTexture(drawable->texture())
	colour->setLoadAction(.Clear)
	colour->setStoreAction(.Store)
	colour->setClearColor(MTL.ClearColor{f64(clear.r), f64(clear.g), f64(clear.b), f64(clear.a)})

	viewport := [2]f32{f32(ts.size_px.x), f32(ts.size_px.y)}
	cb := r.queue->commandBuffer()
	r.blur_tex = nil

	// Opening the scene encoder is a closure because a .Blur batch has to
	// close it, run the blur passes, and open another that *loads* what was
	// already drawn rather than clearing it.
	scene_enc :: proc(r: ^Renderer, cb: ^MTL.CommandBuffer, drawable_tex: ^MTL.Texture,
		clear: [4]f32, first: bool, viewport: ^[2]f32) -> ^MTL.RenderCommandEncoder {
		pass := MTL.RenderPassDescriptor.renderPassDescriptor()
		a := pass->colorAttachments()->object(0)
		a->setTexture(drawable_tex)
		a->setLoadAction(first ? .Clear : .Load)
		a->setStoreAction(.Store)
		if first do a->setClearColor(MTL.ClearColor{f64(clear.r), f64(clear.g), f64(clear.b), f64(clear.a)})
		e := cb->renderCommandEncoderWithDescriptor(pass)
		e->setRenderPipelineState(r.pipeline)
		e->setVertexBuffer(r.vbuf, 0, 0)
		e->setVertexBytes(([^]byte)(viewport)[:size_of([2]f32)], 1)
		e->setFragmentSamplerState(r.sampler, 0)
		return e
	}

	dtex := drawable->texture()
	enc := scene_enc(r, cb, dtex, clear, true, &viewport)

	for b in r.batches {
		if b.kind == .Blur {
			// Everything so far is on the drawable; blur it and carry on.
			enc->endEncoding()
			blur_run(r, cb, dtex, ts.size_px, b.blur)
			enc = scene_enc(r, cb, dtex, clear, false, &viewport)
			continue
		}
		if b.count == 0 do continue
		page := b.page if b.page != 0 else r.white
		tex: ^MTL.Texture
		if page == BLUR_PAGE {
			tex = r.blur_tex // nil until a .Blur batch has run: falls back below
		} else if ps := page_state(r, page); ps != nil {
			tex = ps.tex
		}
		if tex == nil do if ps := page_state(r, r.white); ps != nil do tex = ps.tex
		enc->setFragmentTexture(tex, 0)
		// A canvas is sampled by its own format's rules, where an atlas is
		// always plain linear: through the mip chain when it has one, and
		// with the nearest texel in a format the device will not filter.
		if ps := page_state(r, page); ps != nil && ps.canvas {
			if ps.canvas_format not_in r.canvas_filtered {
				enc->setFragmentSamplerState(r.nearest_sampler, 0)
			} else {
				enc->setFragmentSamplerState(ps.levels > 1 ? r.mip_sampler : r.sampler, 0)
			}
		} else {
			enc->setFragmentSamplerState(r.sampler, 0)
		}
		enc->setScissorRect(MTL.ScissorRect{
			NS.UInteger(b.scissor.x), NS.UInteger(b.scissor.y),
			NS.UInteger(b.scissor.w), NS.UInteger(b.scissor.h)})
		enc->drawPrimitives(.Triangle, NS.UInteger(b.first), NS.UInteger(b.count))
	}
	enc->endEncoding()

	// During a live resize AppKit stretches the old contents to the new bounds
	// until a frame arrives. `presentsWithTransaction` (set by platform/cocoa's
	// metal_layer) puts the present in the CATransaction that carries the
	// bounds change, so both land together, at the cost of a
	// waitUntilScheduled stall.
	if ts.layer->presentsWithTransaction() {
		cb->commit()
		cb->waitUntilScheduled()
		drawable->present()
		// Only this path has already waited, so only here can the status be
		// read without a stall. A reset or removed GPU shows as an errored
		// command buffer.
		if cb->status() == .Error {
			r.lost = true
			return .Lost
		}
	} else {
		cb->presentDrawable(drawable)
		cb->commit()
	}
	return .OK
}

// -------------------------------------------------------------- frosted glass
//
// The Backdrop command samples BLUR_PAGE: everything drawn on the target so
// far, downsampled and Kawase-blurred. The chain mirrors gpu/blur.odin — a
// quarter-size copy, then a few ping-pong passes with growing offsets — but
// where Vulkan closes its dynamic-rendering scope, blits and reopens with
// loadOp LOAD, Metal ends the render encoder, runs each pass as its own
// encoder, and begins a new one on the drawable with loadAction .Load.
//
// The downsample is a full-screen draw rather than a blit, which needs no
// transfer usage on the drawable and lets the linear sampler do the
// filtering. It does need the layer to be sampleable, which is why
// platform/cocoa turns framebufferOnly off.

BLUR_DIVISOR :: u32(4)

@(private)
Blur_State :: struct {
	size:  [2]u32,
	tex:   [2]^MTL.Texture,
	ready: bool,
}

@(private)
Blur_Push :: struct {
	texel:  [2]f32,
	offset: f32,
	pad:    f32,
}

@(private)
blur_ensure :: proc(r: ^Renderer, size_px: [2]u32) -> bool {
	want := [2]u32{max(size_px.x / BLUR_DIVISOR, 1), max(size_px.y / BLUR_DIVISOR, 1)}
	if r.blur.ready && r.blur.size == want do return true
	blur_destroy(r)
	for i in 0 ..< 2 {
		td := MTL.TextureDescriptor.alloc()->init()
		defer td->release()
		td->setTextureType(._2D)
		td->setPixelFormat(.BGRA8Unorm_sRGB) // the scene's own space
		td->setWidth(NS.UInteger(want.x))
		td->setHeight(NS.UInteger(want.y))
		td->setUsage({.RenderTarget, .ShaderRead})
		t := r.dev->newTextureWithDescriptor(td)
		if t == nil { blur_destroy(r); return false }
		r.blur.tex[i] = t
	}
	r.blur.size = want
	r.blur.ready = true
	return true
}

@(private)
blur_destroy :: proc(r: ^Renderer) {
	for i in 0 ..< 2 do if r.blur.tex[i] != nil {
		r.blur.tex[i]->release()
		r.blur.tex[i] = nil
	}
	r.blur.ready = false
}

// blur_run fills r.blur_tex with the scene so far, blurred. `scene` is the
// texture everything has been drawn into — the drawable's.
@(private)
blur_run :: proc(r: ^Renderer, cb: ^MTL.CommandBuffer, scene: ^MTL.Texture, size_px: [2]u32, radius: f32) {
	if !blur_ensure(r, size_px) do return

	draw_into :: proc(r: ^Renderer, cb: ^MTL.CommandBuffer, dst, src: ^MTL.Texture,
		pipe: ^MTL.RenderPipelineState, push: ^Blur_Push) {
		pass := MTL.RenderPassDescriptor.renderPassDescriptor()
		a := pass->colorAttachments()->object(0)
		a->setTexture(dst)
		a->setLoadAction(.DontCare)
		a->setStoreAction(.Store)
		enc := cb->renderCommandEncoderWithDescriptor(pass)
		enc->setRenderPipelineState(pipe)
		enc->setFragmentTexture(src, 0)
		enc->setFragmentSamplerState(r.sampler, 0)
		if push != nil do enc->setFragmentBytes(([^]byte)(push)[:size_of(Blur_Push)], 0)
		enc->drawPrimitives(.Triangle, 0, 3)
		enc->endEncoding()
	}

	// the quarter-size copy
	draw_into(r, cb, r.blur.tex[0], scene, r.copy_pipeline, nil)

	// Kawase ping-pong, the same counts and offsets gpu/blur.odin uses
	passes := clamp(int(radius / 8) + 1, 2, 6)
	scale := radius / (f32(passes) * f32(BLUR_DIVISOR) * 1.5)
	src, dst := 0, 1
	for i in 0 ..< passes {
		push := Blur_Push{
			texel  = {1 / f32(r.blur.size.x), 1 / f32(r.blur.size.y)},
			offset = f32(i) * scale,
		}
		draw_into(r, cb, r.blur.tex[dst], r.blur.tex[src], r.blur_pipeline, &push)
		src, dst = dst, src
	}
	r.blur_tex = r.blur.tex[src] // the last one written
}
