// gpu_reset — does an app come through a GPU reset?
//
// It draws, makes a canvas, then tells the renderer its device is gone (the
// same state a real reset leaves) and watches what happens: the device
// built again, the text and pictures uploaded again, the app told its
// canvases went, and frames carrying on. Run it on a software device first:
//
//   VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/lvp_icd.json ./build/gpu_reset
package main

import "core:fmt"
import "core:os"
import "baldr:baldr"
import "baldr:gpu"

State :: struct {
	g:        baldr.Gpu,
	canvas:   baldr.Canvas,
	frames:   int,
	broke_at: int,
	resets:   int,
	after:    int, // frames drawn since the reset
}

Msg :: union { Ready, Tick, Reset }
Ready :: struct { gpu: baldr.Gpu }
Tick  :: struct {}
Reset :: struct {}

main :: proc() {
	baldr.run(baldr.App(State, Msg){
		title = "gpu reset", app_id = "baldr.gpureset", size = {420, 200},
		init = proc() -> State { return {} },
		start = proc(s: ^State) -> baldr.Cmd(Msg) {
			return baldr.gpu_open(Msg, proc(e: baldr.Ev(baldr.Gpu)) -> Msg { return Ready{e.value} })
		},
		subscriptions = proc(s: ^State, out: ^[dynamic]baldr.Sub(Msg)) {
			append(out, baldr.every(Msg, 100, Tick{}))
		},
		gpu_reset = proc(s: ^State) -> baldr.Cmd(Msg) {
			s.resets += 1
			ok := !baldr.canvas_valid(s.g, s.canvas)
			fmt.printfln("app told: the GPU was reset (canvas gone: %v, device generation %d)",
				ok, gpu.generation(baldr.gpu_renderer(s.g)))
			s.canvas = 0
			return {}
		},
		update = proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) {
			switch v in m {
			case Ready:
				s.g = v.gpu
				c, ok := baldr.canvas_create(s.g, {256, 256})
				if !ok { fmt.println("no canvas"); os.exit(1) }
				s.canvas = c
				baldr.canvas_fill(s.g, c, 0, 0, 256, 256, {0.2, 0.6, 1, 1})
				fmt.println("canvas made and filled")
			case Tick:
				s.frames += 1
				if s.frames == 10 && s.broke_at == 0 {
					s.broke_at = s.frames
					fmt.println("--- telling the renderer its device is gone")
					return baldr.Cmd(Msg){} // the break happens in the view, which has the renderer
				}
				if s.broke_at > 0 do s.after += 1
				if s.after > 20 {
					fmt.printfln("--- %d frames after the reset, resets seen: %d", s.after, s.resets)
					os.exit(0 if s.resets == 1 else 2)
				}
			case Reset:
			}
			return {}
		},
		view = proc(s: ^State, ui: ^baldr.Ui(Msg)) {
			baldr.column(ui, gap = .md, padding = .lg, flex = 1); {
				defer baldr.end(ui)
				baldr.text(ui, "A GPU reset, on purpose", role = .Headline)
				baldr.text(ui, fmt.tprintf("frames %d · resets %d · after %d", s.frames, s.resets, s.after), muted = true)
				if s.canvas != 0 do baldr.text(ui, "canvas alive", muted = true)
			}
			if s.broke_at > 0 && s.resets == 0 do gpu.simulate_device_lost(baldr.gpu_renderer(s.g))
		},
	})
}
