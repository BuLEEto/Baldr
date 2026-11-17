package main

// A music app's albums — covers filling their squares, the
// album's name and its artist under each, Play over the cover on hover.

import "core:fmt"
import "core:math"
import "baldr:baldr"

NAMES := [?]string{"Kind of Blue", "In Rainbows", "Blue Train", "OK Computer", "The Köln Concert", "Discovery",
	"Rumours", "Songs in the Key of Life", "Remain in Light", "Heroes", "Ágætis byrjun", "Blackstar"}
ARTISTS := [?]string{"Miles Davis", "Radiohead", "John Coltrane", "Radiohead", "Keith Jarrett", "Daft Punk",
	"Fleetwood Mac", "Stevie Wonder", "Talking Heads", "David Bowie", "Sigur Rós", "David Bowie"}

State :: struct {
	covers: [12]baldr.Image,
	sel:    baldr.Selection,
}

Msg :: union { Play, Open }
Play :: struct { i: int }
Open :: struct { i: int }

view :: proc(s: ^State, ui: ^baldr.Ui(Msg)) {
	baldr.column(ui, flex = 1, padding = .md); defer baldr.end(ui)
	first, last := baldr.icon_view(ui, len(NAMES), &s.sel, label = "Albums", variant = .Pictures,
		on_activate = proc(e: baldr.Ev(int)) -> Msg { return Open{e.value} })
	for i in first ..< last {
		cover := &s.covers[i] if i != 3 else nil // one without a cover
		baldr.icon_item(ui, i, .Disc_3, NAMES[i], cover, subtitle = ARTISTS[i], action = Msg(Play{i}), action_label = "Play")
	}
	baldr.end(ui)
}

main :: proc() {
	baldr.run(baldr.App(State, Msg){
		title = "Albums", app_id = "dev.baldr.albums", size = {760, 520},
		init = proc() -> (s: State) {
			s.sel = baldr.selection_make(multi = false)
			for &c, i in s.covers { // a gradient per album, not square (cropped, not letterboxed)
				w, h := 240, 200
				px := make([]u8, w * h * 4, context.temp_allocator)
				hue := f32(i) / 12
				for y in 0 ..< h do for x in 0 ..< w {
					t := f32(x + y) / f32(w + h)
					px[(y * w + x) * 4 + 0] = u8(128 + 127 * math.sin(6.28 * (hue + t * 0.3)))
					px[(y * w + x) * 4 + 1] = u8(128 + 127 * math.sin(6.28 * (hue + 0.33 + t * 0.3)))
					px[(y * w + x) * 4 + 2] = u8(128 + 127 * math.sin(6.28 * (hue + 0.66 + t * 0.3)))
					px[(y * w + x) * 4 + 3] = 255
				}
				c, _ = baldr.image_from_rgba(w, h, px)
			}
			return
		},
		update = proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) {
			switch v in m {
			case Play: fmt.eprintln("albums: play", v.i)
			case Open: fmt.eprintln("albums: open", v.i)
			}
			return {}
		},
		view = view,
	})
}
