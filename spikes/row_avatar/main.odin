package main

// What the four kinds of leading slot look like beside each other.
// A messenger's sidebar is avatars, and an avatar has to sit where an icon
// or an initial sits without the rows jumping about.
//
//	./build.sh spike row_avatar run

import "core:math"
import "baldr:baldr"

Msg :: union { int }

State :: struct {
	face:  baldr.Image,
	stripe: baldr.Image,
	made:  bool,
}

// A face to stand in for a photograph: a soft radial wash, so the circular
// crop is obvious at the corners and the picture is clearly not an icon.
make_face :: proc(s: ^State) {
	W :: 96
	px := make([]u8, W * W * 4)
	for y in 0 ..< W {
		for x in 0 ..< W {
			fx, fy := f32(x) / W - 0.45, f32(y) / W - 0.35
			d := math.sqrt(fx * fx + fy * fy)
			i := (y * W + x) * 4
			px[i + 0] = u8(clamp(240 - d * 230, 0, 255))
			px[i + 1] = u8(clamp(170 - d * 90, 0, 255))
			px[i + 2] = u8(clamp(90 + d * 180, 0, 255))
			px[i + 3] = 255
		}
	}
	s.face, _ = baldr.image_from_rgba(W, W, px)
	delete(px)

	// …and a wide one, to show a non-square picture is cropped to fill
	// rather than squashed into an oval.
	WW, HH :: 160, 60
	px2 := make([]u8, WW * HH * 4)
	for y in 0 ..< HH {
		for x in 0 ..< WW {
			i := (y * WW + x) * 4
			on := ((x / 10) + (y / 10)) % 2 == 0
			px2[i + 0] = 230 if on else 40
			px2[i + 1] = 90 if on else 40
			px2[i + 2] = 120 if on else 60
			px2[i + 3] = 255
		}
	}
	s.stripe, _ = baldr.image_from_rgba(WW, HH, px2)
	delete(px2)
	s.made = true
}

view :: proc(s: ^State, ui: ^baldr.Ui(Msg)) {
	if !s.made do make_face(s)
	baldr.column(ui, padding = .lg, gap = .lg); defer baldr.end(ui)

	// What a messenger's sidebar is: every leading slot the same circle,
	// whether the contact has a picture or only an initial.
	baldr.text(ui, "Avatar rows — the labels must all start at one x", role = .Title)
	baldr.column(ui, gap = .xxs)
	{
		defer baldr.end(ui)
		baldr.list_row(ui, "Ada Lovelace", Msg(1), image = &s.face, detail = "see you then", value = "09:12", variant = .Avatar, key = 1)
		baldr.list_row(ui, "Bo Nielsen", Msg(2), glyph = "B", detail = "no picture — the initial stands in", variant = .Avatar, key = 2)
		baldr.list_row(ui, "Wide picture", Msg(3), image = &s.stripe, detail = "cropped to fill, not squashed", variant = .Avatar, key = 3)
		baldr.list_row(ui, "Design team", Msg(4), image = &s.face, image_round = false, detail = "a group: a rounded square in the same slot", variant = .Avatar, key = 4)
		baldr.list_row(ui, "Saved messages", Msg(5), icon = .Bookmark, detail = "an icon in the circle", variant = .Avatar, key = 5)
	}

	baldr.text(ui, "Plain rows — a picture is an icon's size here", role = .Title)
	baldr.column(ui, gap = .xxs)
	{
		defer baldr.end(ui)
		baldr.list_row(ui, "Ada Lovelace", Msg(6), image = &s.face, detail = "lines up with the rows below", key = 6)
		baldr.list_row(ui, "Bo Nielsen", Msg(7), glyph = "B", detail = "an initial", key = 7)
		baldr.list_row(ui, "Saved messages", Msg(8), icon = .Bookmark, detail = "an icon, as before", key = 8)
	}

	baldr.text(ui, "Tiled rows", role = .Title)
	baldr.column(ui, gap = .xxs)
	{
		defer baldr.end(ui)
		baldr.list_row(ui, "Ada Lovelace", Msg(9), image = &s.face, detail = "in a square tile", variant = .Tile, key = 9)
		baldr.list_row(ui, "Calculator", Msg(10), icon = .Star, detail = "an accent tile", variant = .Accent, key = 10)
	}
}

main :: proc() {
	baldr.run(baldr.App(State, Msg){
		title = "Row avatars", app_id = "baldr.row_avatar", size = {470, 640},
		view = view,
		update = proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) { return {} },
	})
}
