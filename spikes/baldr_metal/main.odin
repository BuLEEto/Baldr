#+build darwin
package main

// A Baldr app on macOS. Real widgets, laid out and painted by the real
// toolkit, turned into draw commands by the real renderer front end, batched
// by the real batcher, and drawn by Metal into a window from platform/cocoa.
// No Vulkan and no MoltenVK anywhere in it.
//
// It does not go through `app.odin`'s runtime, because
// that creates a `gpu.Renderer` and asks the backend for a VkSurfaceKHR. The
// `gpu` package's Vulkan half has to be split from its shared half before
// that works. Everything above the renderer — the tree, layout, paint, text,
// the widgets, the event plumbing — is the shipping code, unmodified.
//
// The frame, which is app.odin's own sequence with one step swapped:
//   view()                       build the tree from state
//   frame(tree, size)            layout and paint
//   render_prepare(...)          draw list -> []gpu.Cmd, filling the atlas
//   gpu.build_batches(...)       -> []gpu.Vertex + []gpu.Batch   (shared)
//   draw with Metal              <- instead of gpu.render's Vulkan path

import CA "vendor:darwin/QuartzCore"
import MTL "vendor:darwin/Metal"
import NS "vendor:darwin/AppKit"
import "core:fmt"
import "core:os"
import "core:time"
import "baldr:baldr"
import "baldr:gpu"
import "baldr:platform"
import "baldr:platform/cocoa"

BUDGET :: 30

main :: proc() {
	pool := NS.AutoreleasePool.alloc()->init()
	defer pool->drain()

	b := cocoa.backend()
	ok, why := b.init(b)
	if !ok { fmt.eprintfln("backend: %s", why); os.exit(1) }
	defer b.shutdown(b)

	surf, made := b.surface_create(b, platform.Surface_Desc{title = "Baldr — Metal", size = {760, 520}})
	if !made { fmt.eprintln("no surface"); os.exit(1) }

	layer := cocoa.metal_layer(b, surf)
	if layer == nil { fmt.eprintln("no CAMetalLayer"); os.exit(1) }

	r := renderer_make(layer)
	defer renderer_destroy(&r)

	ui: baldr.Ui(Msg)
	baldr.ui_init(&ui)
	defer baldr.ui_destroy(&ui)

	// The text engine, which app.odin creates and hands to every tree. Without
	// it a Tree falls back to the headless mono measurer: it lays out as though
	// text were there and draws none of it.
	te: baldr.Text_Engine
	if !baldr.text_engine_init(&te) { fmt.eprintln("fonts failed to load"); os.exit(1) }
	defer baldr.text_engine_destroy(&te)
	baldr.tree_use_text_engine(&ui.tree, &te)

	state: State

	// The atlas lives on the GPU: Baldr hands pages to this sink and the
	// renderer binds them as textures. Exactly what app.odin does, with
	// gpu.atlas_create/upload swapped for Metal.
	sink := baldr.Atlas_Sink{
		user   = &r,
		create = atlas_create,
		upload = atlas_upload,
	}

	cmds: [dynamic]gpu.Cmd
	defer delete(cmds)

	size, _, scale := b.surface_geometry(b, surf)
	fmt.printfln("surface %.0fx%.0f at scale %.2f", size.x, size.y, scale)

	start := time.tick_now()
	frames := 0
	running := true
	for running && time.duration_seconds(time.tick_since(start)) < BUDGET {
		for ev in b.pump(b, 8) {
			// `#partial`: only the events this spike acts on, so a new
			// `platform.Event` variant does not break it.
			#partial switch e in ev {
			case platform.Ev_Configure:
				size, scale = e.size, e.scale
			case platform.Ev_Close:
				running = false
			case platform.Ev_Pointer_Motion:
				baldr.pointer_move(&ui, e.pos)
			case platform.Ev_Pointer_Button:
				if e.button == .Left do baldr.pointer_button(&ui, .Left, e.pressed, e.pos)
			case platform.Ev_Pointer_Enter:
				baldr.pointer_move(&ui, e.pos)
			case platform.Ev_Pointer_Leave:
				baldr.pointer_leave(&ui)
			}
		}

		// the app's own update, from whatever the widgets sent
		for m in ui.msgs {
			switch v in m {
			case Press:  state.presses += 1
			case Toggle: state.on = v.on
			}
		}
		clear(&ui.msgs)

		now := f64(time.duration_milliseconds(time.tick_since(start)))
		ui.tree.now_ms = now
		// app.odin's per-frame tick: steps the tweens, sweeps exiting nodes
		// and runs the post-event work. Without it a toggle flips its state
		// but its knob never moves.
		baldr.ui_tick(&ui, now)
		view(&ui, &state)
		baldr.frame(&ui.tree, size)

		clear(&cmds)
		baldr.render_prepare(&ui.tree, scale, &sink, &cmds)
		draw(&r, cmds[:], {u32(size.x * scale), u32(size.y * scale)})
		if frames == 60 {
			kinds: map[string]int
			defer delete(kinds)
			for c in cmds {
				switch _ in c {
				case gpu.Quad:      kinds["Quad"] += 1
				case gpu.Glyph:     kinds["Glyph"] += 1
				case gpu.Shadow:    kinds["Shadow"] += 1
				case gpu.Image:     kinds["Image"] += 1
				case gpu.Backdrop:  kinds["Backdrop"] += 1
				case gpu.Glow:      kinds["Glow"] += 1
				case gpu.Highlight: kinds["Highlight"] += 1
				case gpu.Line:      kinds["Line"] += 1
				case gpu.Clip_Push: kinds["Clip_Push"] += 1
				case gpu.Clip_Pop:  kinds["Clip_Pop"] += 1
				}
			}
			fmt.printfln("frame 60: %d cmds -> %d verts in %d batches; pages=%d",
				len(cmds), len(r.batcher.verts), len(r.batcher.batches), r.n_pages)
			for k, n in kinds do fmt.printfln("   %-10s %d", k, n)
			fmt.printfln("   tree has %d nodes, text engine: %v", len(ui.tree.nodes), ui.tree.text != nil)
		}
		frames += 1
	}
	secs := time.duration_seconds(time.tick_since(start))
	fmt.printfln("--- %d frames in %.1f s (%.0f fps), %d presses, toggle %v ---",
		frames, secs, f64(frames) / secs, state.presses, state.on)
	b.surface_destroy(b, surf)
}
