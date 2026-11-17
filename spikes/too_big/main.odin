package main

// Does a picture the device cannot take say so? When the GPU refuses a
// picture its own texture, it falls back to the atlas, which scales
// anything over a page down by a whole factor to fit; done silently, an app
// would get a smear and no reason for it.
//
// A 20,000 px wide picture is past the 16,384 most cards allow and costs
// only 8 MB, where an animation big enough to overflow would cost a
// gigabyte. Expect one line on stderr, once, naming the size.
//
//	./build.sh spike too_big run

import "core:fmt"
import "baldr:baldr"

Msg :: union { int }

W :: 20_000
H :: 100

State :: struct {
	wide: baldr.Image,
	made: bool,
}

main :: proc() {
	baldr.run(baldr.App(State, Msg){
		title = "too big", app_id = "baldr.too_big", size = {420, 260},
		view = proc(s: ^State, ui: ^baldr.Ui(Msg)) {
			if !s.made {
				px := make([]u8, W * H * 4)
				defer delete(px)
				for i in 0 ..< W * H {
					on := (i % 2) == 0
					v: u8 = 240 if on else 16
					px[i * 4 + 0], px[i * 4 + 1], px[i * 4 + 2], px[i * 4 + 3] = v, v, v, 255
				}
				ok: bool
				s.wide, ok = baldr.image_from_rgba(W, H, px)
				fmt.printfln("made a %d x %d picture: %v (the device allows 16384)", W, H, ok)
				s.made = true
			}
			baldr.column(ui, padding = .md, gap = .sm); defer baldr.end(ui)
			baldr.text(ui, "a picture wider than the device allows", role = .Caption, muted = true)
			baldr.image(ui, &s.wide, width = 380)
		},
		update = proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) { return {} },
	})
}
