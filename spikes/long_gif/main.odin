package main

// A 480x270 animation of 100 frames, an ordinary reaction GIF, must animate
// sharp. Stacked in one column it would be 27,000 px tall, past what any GPU
// takes, and the atlas fallback downscales anything over a page to a smudge;
// the frames are laid out in a grid instead.
//
//	./build.sh spike long_gif run
//
// The content is deliberately hard on a downscale: one-pixel checks, a
// hairline grid and a sliding bar. If any of that is soft, the picture is
// not being drawn from its own texels.

import "core:fmt"
import "baldr:baldr"

Msg :: union { int }

W :: 480
H :: 270
N :: 100

State :: struct {
	gif:  baldr.Image,
	made: bool,
}

build_frames :: proc() -> baldr.Image {
	frames := make([][]u8, N)
	delays := make([]int, N)
	defer {
		for f in frames do delete(f)
		delete(frames)
		delete(delays)
	}
	for i in 0 ..< N {
		px := make([]u8, W * H * 4)
		for y in 0 ..< H {
			for x in 0 ..< W {
				o := (y * W + x) * 4
				// one-pixel checks: the first thing a downscale destroys
				on := (x + y) % 2 == 0
				v: u8 = 235 if on else 20
				px[o + 0], px[o + 1], px[o + 2], px[o + 3] = v, v, v, 255
				// a hairline grid every 16 px, in red
				if x % 16 == 0 || y % 16 == 0 {
					px[o + 0], px[o + 1], px[o + 2] = 220, 40, 40
				}
				// the frame's own sliding bar, in blue
				bar := i * W / N
				if x >= bar && x < bar + 12 {
					px[o + 0], px[o + 1], px[o + 2] = 60, 120, 255
				}
			}
		}
		frames[i] = px
		delays[i] = 40
	}
	img, ok := baldr.image_from_rgba_frames(W, H, frames, delays)
	fmt.printfln("image_from_rgba_frames(%d x %d, %d frames) -> ok %v, texture %d x %d, %d cols, %d frames kept",
		W, H, N, ok, img.width, img.height, img.cols, img.frames)
	fmt.printfln("  (one column would have been %d x %d)", W, H * N)
	return img
}

main :: proc() {
	baldr.run(baldr.App(State, Msg){
		title = "long gif", app_id = "baldr.long_gif", size = {560, 400},
		view = proc(s: ^State, ui: ^baldr.Ui(Msg)) {
			if !s.made {
				s.gif = build_frames()
				s.made = true
			}
			baldr.column(ui, padding = .md, gap = .sm); defer baldr.end(ui)
			baldr.text(ui, fmt.tprintf("%d frames, texture %d x %d", s.gif.frames, s.gif.width, s.gif.height),
				role = .Caption, muted = true)
			// drawn at its own size: one picture pixel per logical pixel,
			// so anything soft is the texture and not the scaling
			baldr.image(ui, &s.gif, width = W, height = H)
		},
		update = proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) { return {} },
	})
}
