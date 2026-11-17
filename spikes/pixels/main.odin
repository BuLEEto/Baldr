package main

// How a magnified picture is sampled, and the pixel grid. Three rows, all
// of the same two little pictures drawn larger:
//
//   1. Auto at 2 ×, 3 ×, 4 ×, 6 × device pixels a texel. This is the
//      crossover: soft at 2, half-way at 3, hard from 4. Looked at left to
//      right it should sharpen smoothly, with no step between any two.
//   2. The same size (4 ×) forced Smooth, left to Auto and Hard: the first
//      soft, the other two identical and crisp.
//   3. `pixel_grid` at 8 ×, 16 ×, 24 ×: a 1-pixel line between texels, barely
//      none at 8 (the floor) and fully there at 24. Its ink is dark over the
//      light half, light over the dark half, and mid grey over the wholly
//      transparent column, which is the only ink that shows on either.

import "baldr:baldr"

State :: struct { checks, patches: baldr.Image }
Msg :: enum { None }

CHECK :: 16
PATCH :: 8

main :: proc() {
	baldr.run(baldr.App(State, Msg){
		title = "Pixels", app_id = "dev.baldr.pixels", size = {900, 760},
		init = proc() -> (s: State) {
			// a checkerboard: the clearest thing to judge soft against hard on
			px := make([]u8, CHECK * CHECK * 4, context.temp_allocator)
			for y in 0 ..< CHECK do for x in 0 ..< CHECK {
				v: u8 = 230 if (x + y) % 2 == 0 else 40
				i := (y * CHECK + x) * 4
				px[i + 0], px[i + 1], px[i + 2], px[i + 3] = v, v, v, 255
			}
			s.checks, _ = baldr.image_from_rgba(CHECK, CHECK, px)

			// patches for the grid: a light half, a dark half, and one wholly
			// transparent column, so all three of the grid's inks are on screen
			pt := make([]u8, PATCH * PATCH * 4, context.temp_allocator)
			for y in 0 ..< PATCH do for x in 0 ..< PATCH {
				i := (y * PATCH + x) * 4
				if x == PATCH - 1 { continue } // transparent: zeroed already
				base: u8 = 215 if x < PATCH / 2 else 35
				wobble := u8((x * 7 + y * 11) % 24)
				v := base + wobble
				pt[i + 0], pt[i + 1], pt[i + 2], pt[i + 3] = v, v, v, 255
			}
			s.patches, _ = baldr.image_from_rgba(PATCH, PATCH, pt)
			return
		},
		view = proc(s: ^State, ui: ^baldr.Ui(Msg)) {
			baldr.column(ui, gap = f32(12), padding = f32(16)); defer baldr.end(ui)

			baldr.text(ui, "Auto: 2x, 3x, 4x, 6x — soft to hard, no step")
			{
				baldr.row(ui, gap = f32(12), align = .End); defer baldr.end(ui)
				for mag, i in ([]f32{2, 3, 4, 6}) {
					side := f32(CHECK) * mag
					baldr.image(ui, &s.checks, width = side, height = side, key = u64(10 + i))
				}
			}

			baldr.text(ui, "4x forced Smooth, then Auto, then Hard — the last two alike")
			{
				baldr.row(ui, gap = f32(12), align = .End); defer baldr.end(ui)
				side := f32(CHECK) * 4
				baldr.image(ui, &s.checks, width = side, height = side, pixelated = false, key = 20)
				baldr.image(ui, &s.checks, width = side, height = side, key = 21)
				baldr.image(ui, &s.checks, width = side, height = side, pixelated = true, key = 22)
			}

			baldr.text(ui, "pixel_grid: 8x (the floor: none), 16x (half), 24x (full)")
			{
				baldr.row(ui, gap = f32(12), align = .End); defer baldr.end(ui)
				for mag, i in ([]f32{8, 16, 24}) {
					side := f32(PATCH) * mag
					baldr.image(ui, &s.patches, width = side, height = side, pixel_grid = true, key = u64(30 + i))
				}
			}
		},
		update = proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) { return {} },
	})
}
