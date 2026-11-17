// cursor_pic — is the pointer the picture the app drew?
//
// `Backend.surface_set_cursor_image` is how a brush's outline moves with the
// pointer as a drawn outline cannot. A backend without it leaves an editor
// that asked for one silently keeping whatever shape it had last set.
//
// The window is a `pointer_area` with a 48x48 ring as its cursor and the
// hotspot in the middle, which is a size and a hotspot no stock cursor has
// — so "is this ours?" can be answered by asking the platform what the
// cursor's bitmap measures, rather than by squinting at a screenshot.
//
//   ./build.sh spike cursor_pic run        # move the pointer over the window
//
// It stays up until closed, or until `BALDR_CURSOR_SECONDS` have passed.
package main

import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import "baldr:baldr"

RING :: 48
HOT  :: RING / 2

State :: struct {
	ring: baldr.Image,
	secs: int,
	up:   int,
}

Msg :: union { Tick }
Tick :: struct {}

main :: proc() {
	baldr.run(baldr.App(State, Msg){
		title = "cursor picture", app_id = "baldr.cursorpic", size = {480, 320},
		init = proc() -> State {
			s := State{secs = 0}
			if v := os.get_env("BALDR_CURSOR_SECONDS", context.temp_allocator); v != "" {
				s.secs, _ = strconv.parse_int(v)
			}
			s.ring = ring_image()
			return s
		},
		update = proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) {
			s.up += 1
			if s.secs > 0 && s.up >= s.secs do return baldr.quit(Msg)
			return {}
		},
		subscriptions = proc(s: ^State, out: ^[dynamic]baldr.Sub(Msg)) {
			append(out, baldr.every(Msg, 1000, Tick{}))
		},
		view = proc(s: ^State, ui: ^baldr.Ui(Msg)) {
			baldr.column(ui, flex = 1, padding = .lg, gap = .md); defer baldr.end(ui)
			baldr.text(ui, "cursor picture", role = .Headline)
			baldr.text(ui, fmt.tprintf("a %dx%d ring, hotspot %d,%d — move the pointer over the panel", RING, RING, HOT, HOT), muted = true)
			panel := baldr.stack(ui, flex = 1, key = 1); baldr.end(ui)
			baldr.pointer_area(ui, panel, cursor_image = &s.ring, hotspot = {HOT, HOT})
		},
	})
}

// ring_image draws a red ring with a clear middle: distinctive in a
// screenshot, and nothing like a stock cursor.
ring_image :: proc() -> baldr.Image {
	px := make([]u8, RING * RING * 4)
	defer delete(px)
	c := f32(RING) / 2
	for y in 0 ..< RING {
		for x in 0 ..< RING {
			dx, dy := f32(x) + 0.5 - c, f32(y) + 0.5 - c
			d := math.sqrt(dx * dx + dy * dy)
			// a 4 px ring at the edge, softened by one pixel either side
			a := f32(0)
			if d > c - 5 && d < c - 1 do a = 1
			else if d > c - 6 && d <= c - 5 do a = d - (c - 6)
			else if d >= c - 1 && d < c do a = (c - d)
			i := (y * RING + x) * 4
			px[i + 0] = 220
			px[i + 1] = 40
			px[i + 2] = 40
			px[i + 3] = u8(clamp(a, 0, 1) * 255)
		}
	}
	img, _ := baldr.image_from_rgba(RING, RING, px)
	return img
}
