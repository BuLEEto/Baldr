#+build darwin
// metal_canvas.odin — canvases on Metal: the recording half of what
// canvas_queue.odin queues, as gpu/canvas.odin is for Vulkan.
//
// The same passes, canvases and ops, and gpu/shaders/canvas.metal is the
// GLSL ported line for line. What differs:
//
//  * No barriers or layouts: Metal orders a texture written by one encoder
//    and read by the next itself.
//  * No descriptor sets: textures bind to the encoder by index, so the
//    "white page where the shader will not read" is just a bind.
//  * A clear is the whole attachment: `loadAction = .Clear` cannot be
//    confined to a scissor, so a `Fill` is a full-screen draw of a constant,
//    and a `Strokes` pass clears its rectangle as a first draw in the same
//    encoder, not a pass of its own.
//  * A blit cannot convert formats, so a copy between canvas formats is a
//    draw (`copy_main`); same-format copies are blits.
//  * A batch is a retained command buffer, not a fence: `canvas_wait` is
//    `waitUntilCompleted` (thread-safe) and `canvas_retire` reads `status()`.
//
// `generateMipmaps` rebuilds a whole texture's chain where canvas.odin blits
// only the changed rectangle: correct, simpler, and more work for a small
// edit to a large canvas. If that shows in a profile, the fix is a blit chain
// like Vulkan's.
package gpu

import "core:mem"
import MTL "vendor:darwin/Metal"
import NS "core:sys/darwin/Foundation"

// Canvas_Wait is what canvas_wait blocks on: the batch's command buffer,
// which Metal lets any thread wait on.
Canvas_Wait :: struct {
	cmd: ^MTL.CommandBuffer,
}

@(private)
Canvas_Batch :: struct {
	id:      u64,
	cmd:     ^MTL.CommandBuffer, // retained
	staging: [dynamic]Buffer,
	reads:   [dynamic]Canvas_Pending_Read,
}

@(private)
Canvas_Pending_Read :: struct {
	id:   u32,
	buf:  Buffer,
	size: int,
}

// Canvas_Pass is one of the canvas pipelines. Each is built per destination
// format, as Vulkan's are, because a render pipeline names its attachment's
// pixel format.
@(private)
Canvas_Pass :: enum u8 { Blend, Transform, Filter, Dab, Stroke, Fill, Copy }

@(private)
CANVAS_SRC :: #load("shaders/canvas.metal", string)

// ---------------------------------------------------------------- push blocks
//
// The same structs the Vulkan push constants use, and the same asserts: MSL
// lays a uniform block out as a vec4-aligned block, which is what these
// already are. `Transform_Push.inv` is three vec4-aligned columns, which is
// byte for byte an MSL `float3x3`.

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

// Fill_Push is fill_main's and copy_main's: a constant to write, or the
// offset from a destination pixel to the source texel.
@(private)
Fill_Push :: struct {
	value: [4]f32,
	off:   [2]i32,
	_:     [2]u32,
}
#assert(size_of(Fill_Push) == 32)

// ------------------------------------------------------------------ formats

@(private)
canvas_metal_format :: proc "contextless" (f: Canvas_Format) -> MTL.PixelFormat {
	switch f {
	case .RGBA8:   return .RGBA8Unorm
	case .RGBA16:  return .RGBA16Unorm
	case .RGBA32F: return .RGBA32Float
	case .R8:      return .R8Unorm
	case .R16:     return .R16Unorm
	}
	return .RGBA8Unorm
}

// canvas_formats_probe notes what the device can do with each canvas format,
// at device creation. Metal has no format query: by its feature tables every
// canvas format is renderable, sampleable, blittable and writable on any
// Metal 2 GPU. The exception is 32-bit float filtering, which Apple silicon
// lacks and `supports32BitFloatFiltering` reports; such an RGBA32F canvas
// gets no mip chain and is drawn nearest (`Limits.filtered`).
@(private)
canvas_formats_probe :: proc(r: ^Renderer) {
	if r.dev == nil do return
	r.canvas_memory = u64(r.dev->recommendedMaxWorkingSetSize())
	float_filter := r.dev->supports32BitFloatFiltering()
	for f in Canvas_Format {
		r.canvas_formats += {f}
		r.canvas_storage += {f}
		if f != .RGBA32F || float_filter do r.canvas_filtered += {f}
	}
}

limits :: proc(r: ^Renderer) -> Limits {
	if r == nil || r.dev == nil do return {}
	// Metal's guaranteed minimum is 16384 on everything Baldr runs on.
	return Limits{
		max_side      = 16384,
		device_memory = r.canvas_memory,
		formats       = r.canvas_formats,
		filtered      = r.canvas_filtered,
		storage       = r.canvas_storage,
	}
}

// ------------------------------------------------------------------ buffers

// canvas_buffer is the Metal half of canvas_queue.odin's buffer helper.
// Metal has no usage flags to declare: a buffer is a buffer, and on Apple
// silicon the default storage mode is already shared with the CPU, which is
// what every one of these needs.
@(private)
canvas_buffer :: proc(r: ^Renderer, size: int, use: Buffer_Use) -> (Buffer, bool) {
	if r.dev == nil || size <= 0 do return {}, false
	buf := r.dev->newBufferWithLength(NS.UInteger(size), {})
	if buf == nil do return {}, false
	return Buffer{buf = buf, size = size, ptr = buf->contents(), use = use}, true
}

@(private)
buffer_destroy :: proc(r: ^Renderer, b: ^Buffer) {
	if b.buf != nil do b.buf->release()
	b^ = {}
}

// ----------------------------------------------------------------- canvases

// canvas_create makes a `size` canvas of `format` in `space`, cleared to
// transparent by the next canvas_flush. 0 when there is no device, a side is
// 0 or past the device's limit, or the memory cannot be had.
canvas_create :: proc(r: ^Renderer, size: [2]u32, format: Canvas_Format, space: Color_Space, mips := true) -> Page {
	return canvas_make(r, size, format, space, clear = true, mips = mips)
}

@(private)
canvas_make :: proc(r: ^Renderer, size: [2]u32, format: Canvas_Format, space: Color_Space, clear: bool, mips := true) -> Page {
	if r.dev == nil || format not_in r.canvas_formats do return 0
	if size.x == 0 || size.y == 0 || size.x > 16384 || size.y > 16384 do return 0
	filtered := format in r.canvas_filtered
	levels: u32 = 1
	// A mip chain costs a third more memory and a rebuild after every batch,
	// so only a canvas shown scaled down asks for one.
	if filtered && mips do for m := max(size.x, size.y); m > 1; m >>= 1 do levels += 1

	slot := -1
	for i in 0 ..< MAX_PAGES do if !r.pages[i].used { slot = i; break }
	if slot < 0 do return 0

	td := MTL.TextureDescriptor.alloc()->init()
	defer td->release()
	td->setTextureType(._2D)
	td->setPixelFormat(canvas_metal_format(format))
	td->setWidth(NS.UInteger(size.x))
	td->setHeight(NS.UInteger(size.y))
	td->setMipmapLevelCount(NS.UInteger(levels))
	// ShaderWrite is what a compute shader of the app's needs; the rest is
	// what every canvas needs — drawn into, sampled, and both ends of a blit.
	td->setUsage({.ShaderRead, .ShaderWrite, .RenderTarget})
	tex := r.dev->newTextureWithDescriptor(td)
	if tex == nil {
		r.last_error = "canvas_create: no memory"
		return 0
	}

	r.pages[slot] = {
		used          = true,
		format        = .RGBA8, // batch.odin's glyph choice; a canvas never uses it
		size          = size,
		levels        = levels,
		tex           = tex,
		canvas        = true,
		canvas_format = format,
		space         = space,
	}
	page := Page(slot + 1)
	if clear do append(&r.canvas_ops, Canvas_Op{kind = .Clear, page = page, w = size.x, h = size.y})
	return page
}

// canvas_scratch is a canvas of `format` at least `size`, kept per format and
// slot for the batch's own working copies (a blend's backdrop, a filter's
// input, the blur's float intermediate).
@(private)
canvas_scratch :: proc(r: ^Renderer, format: Canvas_Format, size: [2]u32, slot := 0) -> ^Page_State {
	page := r.canvas_scratch[slot][format]
	want := size
	if ps := canvas_page(r, page); ps != nil {
		if ps.size.x >= size.x && ps.size.y >= size.y do return ps
		want = {max(ps.size.x, size.x), max(ps.size.y, size.y)} // grow, never shrink
		atlas_destroy(r, page)
	}
	// No mips on a scratch: it is read at level 0 and never shown.
	r.canvas_scratch[slot][format] = canvas_make(r, want, format, .Linear, clear = false, mips = false)
	return canvas_page(r, r.canvas_scratch[slot][format])
}

// ---------------------------------------------------------------- pipelines

// canvas_pipeline is the pipeline for `pass` drawing into canvases of
// `format`, built the first time it is asked for. nil means it could not be
// built, and r.last_error says why.
@(private)
canvas_pipeline :: proc(r: ^Renderer, pass: Canvas_Pass, format: Canvas_Format) -> ^MTL.RenderPipelineState {
	if p := r.canvas_pipelines[pass][format]; p != nil do return p
	if !canvas_library_ensure(r) do return nil

	vert, frag: string
	switch pass {
	case .Blend:     vert, frag = "canvas_fs", "blend_main"
	case .Transform: vert, frag = "canvas_fs", "transform_main"
	case .Filter:    vert, frag = "canvas_fs", "filter_main"
	case .Fill:      vert, frag = "canvas_fs", "fill_main"
	case .Copy:      vert, frag = "canvas_fs", "copy_main"
	case .Dab:       vert, frag = "dab_vert", "dab_frag"
	case .Stroke:    vert, frag = "stroke_vert", "stroke_frag"
	}
	v_fn := r.canvas_lib->newFunctionWithName(NS.String.alloc()->initWithOdinString(vert))
	f_fn := r.canvas_lib->newFunctionWithName(NS.String.alloc()->initWithOdinString(frag))
	if v_fn == nil || f_fn == nil {
		r.last_error = "canvas.metal is missing a function"
		return nil
	}
	defer v_fn->release()
	defer f_fn->release()

	desc := MTL.RenderPipelineDescriptor.alloc()->init()
	defer desc->release()
	desc->setVertexFunction(v_fn)
	desc->setFragmentFunction(f_fn)
	att := desc->colorAttachments()->object(0)
	att->setPixelFormat(canvas_metal_format(format))
	switch pass {
	case .Dab:
		// over: coverage = old + dab × (1 − old), dab after dab in order
		att->setBlendingEnabled(true)
		att->setSourceRGBBlendFactor(.One)
		att->setDestinationRGBBlendFactor(.OneMinusSourceAlpha)
		att->setRgbBlendOperation(.Add)
		att->setSourceAlphaBlendFactor(.One)
		att->setDestinationAlphaBlendFactor(.OneMinusSourceAlpha)
		att->setAlphaBlendOperation(.Add)
	case .Stroke:
		// a maximum, so a stroke's overlapping segments are one coverage
		att->setBlendingEnabled(true)
		att->setSourceRGBBlendFactor(.One)
		att->setDestinationRGBBlendFactor(.One)
		att->setRgbBlendOperation(.Max)
		att->setSourceAlphaBlendFactor(.One)
		att->setDestinationAlphaBlendFactor(.One)
		att->setAlphaBlendOperation(.Max)
	case .Blend, .Transform, .Filter, .Fill, .Copy:
		// these shaders composite themselves and write the final texel
		att->setBlendingEnabled(false)
	}
	pipe, err := r.dev->newRenderPipelineStateWithDescriptor(desc)
	if pipe == nil {
		r.last_error = err != nil ? string(err->localizedDescription()->odinString()) : "canvas pipeline"
		return nil
	}
	r.canvas_pipelines[pass][format] = pipe
	return pipe
}

@(private)
canvas_library_ensure :: proc(r: ^Renderer) -> bool {
	if r.canvas_lib != nil do return true
	if r.dev == nil do return false
	src := NS.String.alloc()->initWithOdinString(CANVAS_SRC)
	opts := MTL.CompileOptions.alloc()->init()
	defer opts->release()
	lib, err := r.dev->newLibraryWithSource(src, opts)
	if lib == nil {
		r.last_error = err != nil ? string(err->localizedDescription()->odinString()) : "canvas.metal did not compile"
		return false
	}
	r.canvas_lib = lib
	return true
}

// ------------------------------------------------------------------ passes

// canvas_encoder opens a render pass over `into`'s level 0, loading what is
// there, with the viewport the whole canvas and the scissor the op's
// rectangle. The viewport is the whole canvas on purpose: it is what makes a
// fragment's `[[position]]` the canvas texel, exactly as the Vulkan half's
// full-viewport-plus-scissor does for `gl_FragCoord`.
@(private)
canvas_encoder :: proc(cb: ^MTL.CommandBuffer, into: ^Page_State, x, y, w, h: u32) -> ^MTL.RenderCommandEncoder {
	pass := MTL.RenderPassDescriptor.renderPassDescriptor()
	a := pass->colorAttachments()->object(0)
	a->setTexture(into.tex)
	a->setLevel(0)
	a->setLoadAction(.Load)
	a->setStoreAction(.Store)
	enc := cb->renderCommandEncoderWithDescriptor(pass)
	if enc == nil do return nil
	enc->setViewport(MTL.Viewport{0, 0, f64(into.size.x), f64(into.size.y), 0, 1})
	enc->setScissorRect(MTL.ScissorRect{NS.UInteger(x), NS.UInteger(y), NS.UInteger(w), NS.UInteger(h)})
	return enc
}

// canvas_blit_texture copies a rectangle between two canvases' level 0.
@(private)
canvas_blit_texture :: proc(cb: ^MTL.CommandBuffer, src: ^Page_State, sx, sy, w, h: u32, dst: ^Page_State, dx, dy: u32) {
	enc := cb->blitCommandEncoder()
	if enc == nil do return
	enc->copyFromTexture(
		src.tex, 0, 0, MTL.Origin{NS.UInteger(sx), NS.UInteger(sy), 0},
		MTL.Size{NS.UInteger(w), NS.UInteger(h), 1},
		dst.tex, 0, 0, MTL.Origin{NS.UInteger(dx), NS.UInteger(dy), 0})
	enc->endEncoding()
}

// canvas_fill_rect writes `value` over the rectangle: the full-screen fill
// draw Metal needs where Vulkan clears an attachment's rectangle. With
// `enc` given it is one more draw in a pass already open (the strokes'
// clear); without, it opens its own.
@(private)
canvas_fill_rect :: proc(r: ^Renderer, cb: ^MTL.CommandBuffer, into: ^Page_State,
	x, y, w, h: u32, value: [4]f32, enc: ^MTL.RenderCommandEncoder = nil) -> bool {
	pipe := canvas_pipeline(r, .Fill, into.canvas_format)
	if pipe == nil do return false
	// Not `defer`: one inside the `if` below would run at the end of that
	// block, before the draw. Closed explicitly, and only when it is ours.
	e, mine := enc, false
	if e == nil {
		e = canvas_encoder(cb, into, x, y, w, h)
		if e == nil do return false
		mine = true
	}
	push := Fill_Push{value = value}
	e->setRenderPipelineState(pipe)
	e->setFragmentBytes(([^]byte)(&push)[:size_of(Fill_Push)], 0)
	e->drawPrimitives(.Triangle, 0, 3)
	if mine do e->endEncoding()
	return true
}

// canvas_white is the texture a shader is given for an input it will not
// read — the solid-colour blend's source, a filter without a table. Vulkan
// binds WHITE_PAGE's descriptor set for the same reason; here it is a bind.
@(private)
canvas_white :: proc(r: ^Renderer) -> ^MTL.Texture {
	if ps := page_state(r, r.white); ps != nil do return ps.tex
	return nil
}

// ------------------------------------------------------------------- flush

// canvas_flush records the queued work into a command buffer of its own and
// commits it; `batch` names it (0: nothing to do, or it failed, which
// r.last_error says) and `reads` says whether it carries reads, which
// canvas_wait and canvas_reads_take then finish. A canvas whose texels
// changed has its smaller levels rebuilt. Call it on the renderer's thread,
// before rendering the frames that show the work.
canvas_flush :: proc(r: ^Renderer) -> (batch: u64, reads: bool) {
	canvas_retire(r)
	staging_age(r)
	writing_closed(r)
	if len(r.canvas_ops) == 0 || r.dev == nil do return

	pool := NS.AutoreleasePool.alloc()->init()
	defer pool->drain()

	// The scratch each format shares is sized for the whole batch before any
	// command is recorded: growing it mid-batch would release a texture an
	// earlier op was already encoded against, and the GPU would read freed
	// memory.
	need: [2][Canvas_Format][2]u32
	grow :: proc(n: ^[2]u32, w, h: u32) { n^ = {max(n.x, w), max(n.y, h)} }
	for op in r.canvas_ops {
		#partial switch op.kind {
		case .Blend, .Transform:
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

	cb := r.queue->commandBuffer()
	if cb == nil {
		r.last_error = "canvas_flush: no command buffer"
		canvas_ops_drop(r)
		return
	}
	// Retained: the one the queue hands out is autoreleased, and the batch
	// outlives this pool by however long the GPU takes.
	cb->retain()
	b := new(Canvas_Batch)
	b.cmd = cb

	touched := make(map[Page][4]u32, context.temp_allocator) // what changed on each, for its levels
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
		switch op.kind {
		case .Clear:
			// The whole canvas, so a loadAction clear does it with no draw.
			// Level 0 only: `touch` marks the whole canvas and the mip rebuild
			// at the end of the batch clears the rest.
			pass := MTL.RenderPassDescriptor.renderPassDescriptor()
			a := pass->colorAttachments()->object(0)
			a->setTexture(ps.tex)
			a->setLevel(0)
			a->setLoadAction(.Clear)
			a->setStoreAction(.Store)
			a->setClearColor(MTL.ClearColor{0, 0, 0, 0})
			enc := cb->renderCommandEncoderWithDescriptor(pass)
			if enc == nil do continue
			enc->endEncoding()
			touch(&touched, op.page, 0, 0, ps.size.x, ps.size.y)
		case .Write:
			bpp := u32(canvas_bpp(ps.canvas_format))
			enc := cb->blitCommandEncoder()
			if enc != nil {
				enc->copyFromBuffer(op.staging.buf, 0, NS.UInteger(op.w * bpp), NS.UInteger(op.w * op.h * bpp),
					MTL.Size{NS.UInteger(op.w), NS.UInteger(op.h), 1},
					ps.tex, 0, 0, MTL.Origin{NS.UInteger(op.x), NS.UInteger(op.y), 0})
				enc->endEncoding()
			}
			append(&b.staging, op.staging)
			touch(&touched, op.page, op.x, op.y, op.w, op.h)
		case .Fill:
			if !canvas_fill_rect(r, cb, ps, op.x, op.y, op.w, op.h, op.value) do continue
			touch(&touched, op.page, op.x, op.y, op.w, op.h)
		case .Copy:
			src := canvas_page(r, op.src)
			if src == nil do continue
			if src.canvas_format == ps.canvas_format {
				// One format: a blit. Within one canvas the rectangles are
				// guaranteed not to overlap by canvas_copy, which is the
				// condition Metal's blit encoder needs too.
				canvas_blit_texture(cb, src, op.sx, op.sy, op.w, op.h, ps, op.x, op.y)
			} else {
				// Two formats: a draw, since a blit cannot convert. src is
				// never ps here — one canvas has one format — so this never
				// reads its own render target.
				pipe := canvas_pipeline(r, .Copy, ps.canvas_format)
				enc := canvas_encoder(cb, ps, op.x, op.y, op.w, op.h)
				if pipe == nil || enc == nil do continue
				push := Fill_Push{off = {i32(op.sx) - i32(op.x), i32(op.sy) - i32(op.y)}}
				enc->setRenderPipelineState(pipe)
				enc->setFragmentTexture(src.tex, 0)
				enc->setFragmentBytes(([^]byte)(&push)[:size_of(Fill_Push)], 0)
				enc->drawPrimitives(.Triangle, 0, 3)
				enc->endEncoding()
			}
			touch(&touched, op.page, op.x, op.y, op.w, op.h)
		case .Transform:
			src := canvas_page(r, op.src)
			if src == nil do continue
			mask := canvas_page(r, op.mask) if op.mask != 0 else nil
			scratch := canvas_scratch(r, ps.canvas_format, {op.w, op.h})
			pipe := canvas_pipeline(r, .Transform, ps.canvas_format)
			if scratch == nil || pipe == nil do continue
			// the backdrop: what is under the rectangle now, so the shader
			// can lay the resampled source over it
			canvas_blit_texture(cb, ps, op.x, op.y, op.w, op.h, scratch, 0, 0)
			enc := canvas_encoder(cb, ps, op.x, op.y, op.w, op.h)
			if enc == nil do continue
			flags := u32(1 if op.linear else 0) | u32(2 if mask != nil else 0) | canvas_curve(ps.space) << 2 | canvas_curve(src.space) << 4
			push := Transform_Push{
				back_off = {-i32(op.x), -i32(op.y)},
				mask_off = {-i32(op.x), -i32(op.y)},
				src_rect = {i32(op.sx), i32(op.sy), i32(op.sw), i32(op.sh)},
				mode = u32(op.mode), flags = flags, kernel = op.kernel, opacity = op.opacity,
			}
			for c in 0 ..< 3 do for row in 0 ..< 3 do push.inv[c][row] = op.inv[c * 3 + row]
			enc->setRenderPipelineState(pipe)
			enc->setFragmentTexture(src.tex, 0)
			enc->setFragmentTexture(scratch.tex, 1)
			enc->setFragmentTexture(mask.tex if mask != nil else canvas_white(r), 2)
			enc->setFragmentBytes(([^]byte)(&push)[:size_of(Transform_Push)], 0)
			enc->drawPrimitives(.Triangle, 0, 3)
			enc->endEncoding()
			touch(&touched, op.page, op.x, op.y, op.w, op.h)
		case .Blend:
			src := canvas_page(r, op.src) if !op.solid else ps // a colour: nothing to sample (bound, never read)
			if src == nil do continue
			mask := canvas_page(r, op.mask) if op.mask != 0 else nil
			scratch := canvas_scratch(r, ps.canvas_format, {op.w, op.h})
			pipe := canvas_pipeline(r, .Blend, ps.canvas_format)
			if scratch == nil || pipe == nil do continue
			// the backdrop: what is under the rectangle now, into the scratch
			canvas_blit_texture(cb, ps, op.x, op.y, op.w, op.h, scratch, 0, 0)
			enc := canvas_encoder(cb, ps, op.x, op.y, op.w, op.h)
			if enc == nil do continue
			flags := u32(1 if op.linear else 0) | u32(2 if mask != nil else 0) | canvas_curve(ps.space) << 2 | canvas_curve(src.space) << 4
			if op.solid do flags |= 64
			if op.erase do flags |= 128
			push := Blend_Push{
				src_off  = {i32(op.sx) - i32(op.x), i32(op.sy) - i32(op.y)},
				back_off = {-i32(op.x), -i32(op.y)},
				mask_off = {i32(op.sx) - i32(op.x), i32(op.sy) - i32(op.y)},
				mode = u32(op.mode), flags = flags, opacity = op.opacity, seed = op.seed, color = op.value,
			}
			enc->setRenderPipelineState(pipe)
			enc->setFragmentTexture(canvas_white(r) if op.solid else src.tex, 0)
			enc->setFragmentTexture(scratch.tex, 1)
			enc->setFragmentTexture(mask.tex if mask != nil else canvas_white(r), 2)
			enc->setFragmentBytes(([^]byte)(&push)[:size_of(Blend_Push)], 0)
			enc->drawPrimitives(.Triangle, 0, 3)
			enc->endEncoding()
			touch(&touched, op.page, op.x, op.y, op.w, op.h)
		case .Filter:
			if !canvas_filter_record(r, cb, &op, ps) do continue
			touch(&touched, op.page, op.x, op.y, op.w, op.h)
		case .Dabs:
			append(&b.staging, op.staging) // the quads: freed with the batch
			pipe := canvas_pipeline(r, .Dab, ps.canvas_format)
			if pipe == nil do continue
			tip := canvas_page(r, op.tip) if op.tip != 0 else nil
			enc := canvas_encoder(cb, ps, op.x, op.y, op.w, op.h)
			if enc == nil do continue
			push := Dab_Push{size = {f32(ps.size.x), f32(ps.size.y)}, tip = 1 if tip != nil else 0}
			enc->setRenderPipelineState(pipe)
			enc->setVertexBuffer(op.staging.buf, 0, 0)
			enc->setVertexBytes(([^]byte)(&push)[:size_of(Dab_Push)], 1)
			enc->setFragmentBytes(([^]byte)(&push)[:size_of(Dab_Push)], 0)
			enc->setFragmentTexture(tip.tex if tip != nil else canvas_white(r), 0)
			// a tip is sampled, so it follows its own format's filtering
			enc->setFragmentSamplerState(
				r.sampler if tip != nil && tip.canvas_format in r.canvas_filtered else r.nearest_sampler, 0)
			enc->drawPrimitives(.Triangle, 0, NS.UInteger(op.count * 6))
			enc->endEncoding()
			touch(&touched, op.page, op.x, op.y, op.w, op.h)
		case .Strokes:
			// Several runs share one buffer; only its owner hands it back.
			if op.own do append(&b.staging, op.staging)
			pipe := canvas_pipeline(r, .Stroke, ps.canvas_format)
			if pipe == nil do continue
			enc := canvas_encoder(cb, ps, op.x, op.y, op.w, op.h)
			if enc == nil do continue
			// Coverage starts from nothing, so the rectangle is cleared first,
			// as a draw in this same pass: Metal cannot confine a clear
			// loadAction to a rectangle.
			if !canvas_fill_rect(r, cb, ps, op.x, op.y, op.w, op.h, {}, enc) {
				enc->endEncoding()
				continue
			}
			push := Stroke_Push{size = {f32(ps.size.x), f32(ps.size.y)}}
			enc->setRenderPipelineState(pipe)
			enc->setVertexBuffer(op.staging.buf, 0, 0)
			enc->setVertexBytes(([^]byte)(&push)[:size_of(Stroke_Push)], 1)
			enc->drawPrimitives(.Triangle, NS.UInteger(op.first * 6), NS.UInteger(op.count * 6))
			enc->endEncoding()
			touch(&touched, op.page, op.x, op.y, op.w, op.h)
		case .Shader:
			if shader_record(r, cb, &op, ps) do touch(&touched, op.page, op.x, op.y, op.w, op.h)
		case .Read:
			size := int(op.w) * int(op.h) * canvas_bpp(ps.canvas_format)
			buf, ok := staging_take(r, size, .Read)
			if !ok {
				append(&b.reads, Canvas_Pending_Read{id = op.id})
				continue
			}
			bpp := u32(canvas_bpp(ps.canvas_format))
			enc := cb->blitCommandEncoder()
			if enc != nil {
				enc->copyFromTexture(ps.tex, 0, 0,
					MTL.Origin{NS.UInteger(op.x), NS.UInteger(op.y), 0},
					MTL.Size{NS.UInteger(op.w), NS.UInteger(op.h), 1},
					buf.buf, 0, NS.UInteger(op.w * bpp), NS.UInteger(op.w * op.h * bpp))
				enc->endEncoding()
			}
			append(&b.reads, Canvas_Pending_Read{id = op.id, buf = buf, size = size})
		}
	}

	// Smaller levels, where a canvas has them and its texels changed.
	// generateMipmaps takes the whole texture, so the rectangle is only what
	// tells us whether to bother.
	for p, _ in touched {
		ps := canvas_page(r, p)
		if ps == nil || ps.levels <= 1 do continue
		enc := cb->blitCommandEncoder()
		if enc == nil do continue
		enc->generateMipmapsForTexture(ps.tex)
		enc->endEncoding()
	}

	clear(&r.canvas_ops)
	cb->commit()
	r.canvas_next_batch += 1
	b.id = r.canvas_next_batch
	append(&r.canvas_batches, b)
	return b.id, len(b.reads) > 0
}

// canvas_filter_record records one filter op: the matrix, curves, convert
// and LUT kinds in a single pass, and a blur or unsharp mask in two (across
// into a float intermediate, then down).
@(private)
canvas_filter_record :: proc(r: ^Renderer, cb: ^MTL.CommandBuffer, op: ^Canvas_Op, ps: ^Page_State) -> bool {
	src := canvas_page(r, op.src)
	if src == nil do return false
	f := op.filter
	x0, y0, x1, y1 := filter_region(src, op^)
	copy_ := canvas_scratch(r, src.canvas_format, {x1 - x0, y1 - y0})
	pipe := canvas_pipeline(r, .Filter, ps.canvas_format)
	if copy_ == nil || pipe == nil do return false
	// the input: the source's rectangle and margin, copied, so a filter may
	// write onto its own canvas
	canvas_blit_texture(cb, src, x0, y0, x1 - x0, y1 - y0, copy_, 0, 0)

	table := canvas_page(r, f.table) if f.kind == .Curves || f.kind == .Lut else nil
	white := canvas_white(r)
	flags := u32(1 if f.linear else 0) | canvas_curve(src.space) << 2 | canvas_curve(ps.space) << 4
	in_max := [2]i32{i32(x1 - x0) - 1, i32(y1 - y0) - 1}
	ox, oy := i32(op.sx - x0), i32(op.sy - y0) // the rectangle within the copy

	pass :: proc(r: ^Renderer, cb: ^MTL.CommandBuffer, into: ^Page_State, pipe: ^MTL.RenderPipelineState,
		x, y, w, h: u32, input, aux: ^MTL.Texture, push: ^Filter_Push) {
		enc := canvas_encoder(cb, into, x, y, w, h)
		if enc == nil do return
		enc->setRenderPipelineState(pipe)
		enc->setFragmentTexture(input, 0)
		enc->setFragmentTexture(aux, 1)
		enc->setFragmentBytes(([^]byte)(push)[:size_of(Filter_Push)], 0)
		enc->drawPrimitives(.Triangle, 0, 3)
		enc->endEncoding()
	}

	push := Filter_Push{flags = flags, a = f.sigma, b = f.amount, c = f.threshold}
	if f.kind == .Blur || f.kind == .Sharpen {
		mid := canvas_scratch(r, .RGBA32F, {op.w, y1 - y0}, 1)
		mid_pipe := canvas_pipeline(r, .Filter, .RGBA32F)
		if mid == nil || mid_pipe == nil do return false
		across := push
		across.kind, across.in_off, across.in_max = 4, {ox, 0}, in_max
		pass(r, cb, mid, mid_pipe, 0, 0, op.w, y1 - y0, copy_.tex, white, &across)
		down := push
		down.kind = 5 if f.kind == .Blur else 6
		down.in_off = {-i32(op.x), -i32(op.y) + oy}
		down.in_max = {i32(op.w) - 1, in_max.y}
		down.aux_off = {-i32(op.x) + ox, -i32(op.y) + oy}
		pass(r, cb, ps, pipe, op.x, op.y, op.w, op.h, mid.tex, copy_.tex, &down)
		return true
	}
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
	pass(r, cb, ps, pipe, op.x, op.y, op.w, op.h, copy_.tex, table.tex if table != nil else white, &push)
	return true
}

// ---------------------------------------------------------- batches, reads

canvas_waiter :: proc(r: ^Renderer, id: u64) -> Canvas_Wait {
	for b in r.canvas_batches do if b.id == id do return {b.cmd}
	return {}
}

// canvas_wait blocks until the batch `w` names is done, on any thread.
canvas_wait :: proc(w: Canvas_Wait) {
	if w.cmd == nil do return
	w.cmd->waitUntilCompleted()
}

@(private)
canvas_batch_done :: proc "contextless" (b: ^Canvas_Batch) -> bool {
	if b.cmd == nil do return true
	s := b.cmd->status()
	return s == .Completed || s == .Error
}

// canvas_reads_take hands over batch `id`'s reads once it is done (after
// canvas_wait), each read's texels in `allocator`, and frees the batch.
// Nil while it is still running. The renderer's thread.
canvas_reads_take :: proc(r: ^Renderer, id: u64, allocator := context.allocator) -> (out: []Canvas_Read_Done, done: bool) {
	for b, i in r.canvas_batches {
		if b.id != id do continue
		if !canvas_batch_done(b) do return nil, false
		list := make([]Canvas_Read_Done, len(b.reads), allocator)
		for rd, k in b.reads {
			list[k] = {id = rd.id}
			if rd.buf.buf == nil do continue
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
		if len(b.reads) == 0 && canvas_batch_done(b) {
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
	for &rd in b.reads do if rd.buf.buf != nil do staging_give(r, &rd.buf)
	delete(b.staging)
	delete(b.reads)
	if b.cmd != nil do b.cmd->release()
	free(b)
}

@(private)
canvas_ops_drop :: proc(r: ^Renderer) {
	for &op in r.canvas_ops do if op.kind == .Write || op.kind == .Dabs || (op.kind == .Strokes && op.own) do staging_give(r, &op.staging)
	clear(&r.canvas_ops)
}

// canvas_idle waits for every canvas batch submitted to finish (the run is
// ending). Metal has no device-wide wait, so it waits on each batch in turn.
canvas_idle :: proc(r: ^Renderer) {
	for b in r.canvas_batches do if b.cmd != nil do b.cmd->waitUntilCompleted()
}

// canvas_shutdown frees every batch and queued op (the renderer is going).
@(private)
canvas_shutdown :: proc(r: ^Renderer) {
	canvas_idle(r)
	canvas_ops_drop(r)
	for b in r.canvas_batches do canvas_batch_free(r, b)
	staging_shutdown(r) // after the two above: both hand their buffers back to it
	for &per_format in r.canvas_pipelines do for &p in per_format do if p != nil {
		p->release()
		p = nil
	}
	if r.canvas_lib != nil {
		r.canvas_lib->release()
		r.canvas_lib = nil
	}
	shader_shutdown(r)
	delete(r.canvas_batches)
	delete(r.canvas_ops)
	r.canvas_batches, r.canvas_ops = nil, nil
	r.canvas_scratch = {}
}
