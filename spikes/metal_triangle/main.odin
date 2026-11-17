#+build darwin
package main

// A Metal triangle in a real window, with no Vulkan and no MoltenVK
// anywhere: macOS's whole chain end to end, as spikes/wl_triangle and
// spikes/win32_triangle are for theirs. Device, CAMetalLayer on our own
// NSView, an MSL shader compiled at runtime, a pipeline, a command buffer, a
// drawable, a frame on screen.
//
// What it is checking, beyond "a triangle appears":
//   - does CAMetalLayer attach to the NSView subclass platform/cocoa already
//     makes, and follow its size and scale?
//   - does newLibraryWithSource compile MSL at runtime, and what does a
//     compile error look like? (Baldr ships offline-compiled shaders, but a
//     runtime path is how a canvas's own shader would work.)
//   - what does nextDrawable cost, and does it block?
//
// Run: build with tools/mac-sync.sh, launch the .app bundle, screenshot it.

import CA "vendor:darwin/QuartzCore"
import MTL "vendor:darwin/Metal"
import NS "vendor:darwin/AppKit"
import "base:intrinsics"
import "core:fmt"
import "core:os"
import "core:time"

BUDGET :: 20

// A triangle with no vertex buffer: the positions live in the shader and are
// picked by vertex_id. Nothing here needs a buffer yet, and leaving it out
// keeps the spike about the chain rather than about memory.
SHADER :: `
#include <metal_stdlib>
using namespace metal;

struct V_Out {
    float4 pos [[position]];
    float4 col;
};

vertex V_Out v_main(uint vid [[vertex_id]]) {
    const float2 p[3] = { float2(0.0, 0.62), float2(-0.62, -0.5), float2(0.62, -0.5) };
    const float3 c[3] = { float3(0.96, 0.33, 0.31), float3(0.36, 0.84, 0.44), float3(0.35, 0.55, 0.98) };
    V_Out o;
    o.pos = float4(p[vid], 0.0, 1.0);
    o.col = float4(c[vid], 1.0);
    return o;
}

fragment float4 f_main(V_Out in [[stage_in]]) {
    return in.col;
}
`

main :: proc() {
	pool := NS.AutoreleasePool.alloc()->init()
	defer pool->drain()

	app := NS.Application.sharedApplication()
	app->setActivationPolicy(.Regular)
	app->finishLaunching()

	rect := NS.Rect{{0, 0}, {720, 480}}
	style := NS.WindowStyleMask{.Titled, .Closable, .Miniaturizable, .Resizable}
	win := NS.Window.alloc()->initWithContentRect(rect, style, .Buffered, false)
	if win == nil { fmt.eprintln("metal_triangle: no window"); os.exit(1) }
	title := "Baldr — Metal triangle"
	win->setTitle(NS.String.alloc()->initWithOdinString(title))

	dev := MTL.CreateSystemDefaultDevice()
	if dev == nil { fmt.eprintln("metal_triangle: no Metal device"); os.exit(1) }
	defer dev->release()
	fmt.printfln("device: %s", dev->name()->odinString())

	// The layer, on the window's content view. `wantsLayer` first, then the
	// layer: setting them the other way round leaves AppKit free to replace
	// the layer with one of its own.
	layer := CA.MetalLayer.layer()
	layer->setDevice(dev)
	layer->setPixelFormat(.BGRA8Unorm)
	layer->setFramebufferOnly(true) // we never read it back; lets Metal pick a better layout

	view := win->contentView()
	view->setWantsLayer(true)
	view->setLayer(layer)

	queue := dev->newCommandQueue()
	if queue == nil { fmt.eprintln("metal_triangle: no command queue"); os.exit(1) }
	defer queue->release()

	// MSL compiled at runtime. Baldr's own shaders ship offline-compiled,
	// but a canvas's own shader needs this path.
	src := NS.String.alloc()->initWithOdinString(SHADER)
	opts := MTL.CompileOptions.alloc()->init()
	defer opts->release()
	lib, lib_err := dev->newLibraryWithSource(src, opts)
	if lib == nil {
		msg := lib_err != nil ? string(lib_err->localizedDescription()->odinString()) : "no error given"
		fmt.eprintfln("metal_triangle: shader did not compile: %s", msg)
		os.exit(1)
	}
	defer lib->release()

	v_fn := lib->newFunctionWithName(NS.AT("v_main"))
	f_fn := lib->newFunctionWithName(NS.AT("f_main"))
	if v_fn == nil || f_fn == nil { fmt.eprintln("metal_triangle: shader entry points missing"); os.exit(1) }
	defer v_fn->release()
	defer f_fn->release()

	desc := MTL.RenderPipelineDescriptor.alloc()->init()
	defer desc->release()
	desc->setVertexFunction(v_fn)
	desc->setFragmentFunction(f_fn)
	desc->colorAttachments()->object(0)->setPixelFormat(.BGRA8Unorm)

	pipeline, pipe_err := dev->newRenderPipelineStateWithDescriptor(desc)
	if pipeline == nil {
		msg := pipe_err != nil ? string(pipe_err->localizedDescription()->odinString()) : "no error given"
		fmt.eprintfln("metal_triangle: pipeline: %s", msg)
		os.exit(1)
	}
	defer pipeline->release()

	// --- the pixels, offscreen.
	//
	// Rendering to a texture and reading it back is better evidence than a
	// screenshot: it needs no screen, no permission and no unobscured
	// window, so it works on a locked machine too.
	offscreen_check(dev, queue, pipeline)

	win->center()
	win->makeKeyAndOrderFront(nil)
	app->activateIgnoringOtherApps(true)
	fmt.printfln("--- drawing for %d s ---", BUDGET)

	frames := 0
	worst_drawable: time.Duration
	start := time.tick_now()
	for time.duration_seconds(time.tick_since(start)) < BUDGET {
		// A pool per frame: Metal hands back autoreleased objects every frame
		// (the drawable, the pass descriptor, the command buffer, the
		// encoder), and with only the outer pool they pile up until exit.
		frame_pool := NS.AutoreleasePool.alloc()->init()
		defer frame_pool->drain()

		// pump, so the window stays alive and resizable while we draw
		until := NS.Date.dateWithTimeIntervalSinceNow(0.001)
		for {
			ev := app->nextEventMatchingMask(NS.EventMaskAny, until, NS.DefaultRunLoopMode, true)
			if ev == nil do break
			app->sendEvent(ev)
		}

		// keep the drawable the size of the view, in real pixels
		b := view->bounds()
		scale := f64(win->backingScaleFactor())
		layer->setDrawableSize({NS.Float(f64(b.size.width) * scale), NS.Float(f64(b.size.height) * scale)})

		mark := time.tick_now()
		drawable := layer->nextDrawable()
		took := time.tick_since(mark)
		if took > worst_drawable do worst_drawable = took
		if drawable == nil do continue
		// Not released: nextDrawable returns an autoreleased object we do not
		// own, and releasing it crashes later in objc_autoreleasePoolPop
		// (EXC_BAD_ACCESS). The frame pool above frees it.

		pass := MTL.RenderPassDescriptor.renderPassDescriptor()
		colour := pass->colorAttachments()->object(0)
		colour->setTexture(drawable->texture())
		colour->setLoadAction(.Clear)
		colour->setStoreAction(.Store)
		colour->setClearColor(MTL.ClearColor{0.09, 0.10, 0.13, 1.0}) // Baldr's dark surface

		cmd := queue->commandBuffer()
		enc := cmd->renderCommandEncoderWithDescriptor(pass)
		enc->setRenderPipelineState(pipeline)
		enc->drawPrimitives(.Triangle, 0, 3)
		enc->endEncoding()
		cmd->presentDrawable(drawable)
		cmd->commit()
		frames += 1
	}

	secs := time.duration_seconds(time.tick_since(start))
	fmt.printfln("--- %d frames in %.1f s (%.0f fps), worst nextDrawable %.1f ms ---",
		frames, secs, f64(frames) / secs, time.duration_milliseconds(worst_drawable))
}

// offscreen_check draws the same triangle into a texture and reads the
// pixels back, so "it renders" is a measurement rather than a claim.
offscreen_check :: proc(dev: ^MTL.Device, queue: ^MTL.CommandQueue, pipeline: ^MTL.RenderPipelineState) {
	N :: 64
	td := MTL.TextureDescriptor.alloc()->init()
	defer td->release()
	td->setTextureType(._2D)
	td->setPixelFormat(.BGRA8Unorm)
	td->setWidth(N)
	td->setHeight(N)
	td->setUsage({.RenderTarget, .ShaderRead})
	td->setStorageMode(.Managed) // readable by the CPU after a blit sync

	tex := dev->newTextureWithDescriptor(td)
	if tex == nil { fmt.eprintln("offscreen: no texture"); return }
	defer tex->release()

	pass := MTL.RenderPassDescriptor.renderPassDescriptor()
	colour := pass->colorAttachments()->object(0)
	colour->setTexture(tex)
	colour->setLoadAction(.Clear)
	colour->setStoreAction(.Store)
	colour->setClearColor(MTL.ClearColor{0.09, 0.10, 0.13, 1.0})

	cmd := queue->commandBuffer()
	enc := cmd->renderCommandEncoderWithDescriptor(pass)
	enc->setRenderPipelineState(pipeline)
	enc->drawPrimitives(.Triangle, 0, 3)
	enc->endEncoding()
	// A Managed texture needs its CPU copy synchronised before getBytes.
	blit := cmd->blitCommandEncoder()
	blit->synchronizeResource(tex)
	blit->endEncoding()
	cmd->commit()
	cmd->waitUntilCompleted()

	px := make([]u8, N * N * 4)
	defer delete(px)
	tex->getBytes(raw_data(px), N * 4, MTL.Region{{0, 0, 0}, {N, N, 1}}, 0)

	at :: proc(px: []u8, x, y: int) -> (r, g, b: int) {
		i := (y * 64 + x) * 4
		return int(px[i + 2]), int(px[i + 1]), int(px[i + 0]) // BGRA
	}
	cr, cg, cb := at(px, 32, 34)  // inside the triangle, near its centroid
	tr, tg, tb := at(px, 2, 2)    // a corner: the clear colour
	fmt.printfln("offscreen %dx%d: centre rgb(%d,%d,%d)  corner rgb(%d,%d,%d)", N, N, cr, cg, cb, tr, tg, tb)

	// The centroid of the triangle is the mean of the three vertex colours:
	// (0.96,0.33,0.31) (0.36,0.84,0.44) (0.35,0.55,0.98) -> ~(142,146,147).
	// The corner is the clear colour, (0.09,0.10,0.13) -> ~(23,26,33).
	near :: proc(got, want, slack: int) -> bool { return got >= want - slack && got <= want + slack }
	tri_ok := near(cr, 142, 28) && near(cg, 146, 28) && near(cb, 147, 28)
	clear_ok := near(tr, 23, 6) && near(tg, 26, 6) && near(tb, 33, 6)
	fmt.printfln("  triangle drawn where expected: %v; cleared where expected: %v", tri_ok, clear_ok)
	if !tri_ok || !clear_ok do fmt.eprintln("  *** the pixels are not what the shader asks for ***")
}
