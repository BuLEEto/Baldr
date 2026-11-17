// 37_custom — a widget of your own: a star rating drawn from scratch with
// `custom`. It paints itself in the theme's colours, previews the stars
// under the pointer, takes a click to rate, Left / Right while focused,
// and tells a screen reader its role, name and value.
//
//   ./build.sh example 37_custom run
package main

import "core:fmt"
import "baldr:baldr"

STARS :: 5
STAR  :: f32(28) // each star's square, logical px
GAP   :: f32(6)

State :: struct {
	rating: int, // 0…STARS, what has been chosen
	hover:  int, // the star under the pointer, 0 when none
}

Msg :: union { Rate, Hover, baldr.Chord }
Rate  :: struct {}
Hover :: struct { star: int }

// stars paints the rating: what is chosen, or what the pointer would choose.
stars :: proc(p: ^baldr.Painter) {
	s := (^State)(p.user)
	shown := s.hover if s.hover > 0 else s.rating
	for i in 0 ..< STARS {
		x := p.rect.x + f32(i) * (STAR + GAP)
		lit := i < shown
		ink := p.theme.color.primary if lit else p.theme.color.outline
		if lit && s.hover > 0 do ink = baldr.mix(ink, p.theme.color.bg, 0.25) // a preview, lighter than a choice
		baldr.draw_icon(p, .Star, {x + 2, p.rect.y + 2}, STAR - 4, ink)
	}
	if p.focused { // the keyboard is here: a line under the stars
		y := p.rect.y + p.rect.h - 1
		baldr.draw_line(p, {p.rect.x, y}, {p.rect.x + p.rect.w, y}, 2, p.theme.color.focus_ring)
	}
}

on_hover :: proc(e: baldr.Ev(baldr.Pointer_At)) -> Msg {
	if !e.value.inside do return Hover{0}
	return Hover{clamp(int(e.value.pos.x / (STAR + GAP)) + 1, 1, STARS)}
}

on_key :: proc(e: baldr.Ev(baldr.Chord)) -> Msg { return e.value }

update :: proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) {
	switch v in m {
	case Rate:  if s.hover > 0 do s.rating = s.hover
	case Hover: s.hover = v.star
	case baldr.Chord:
		#partial switch v.key {
		case .Left:  s.rating = max(s.rating - 1, 0)
		case .Right: s.rating = min(s.rating + 1, STARS)
		case .Home:  s.rating = 0
		case .End:   s.rating = STARS
		}
	}
	return {}
}

view :: proc(s: ^State, ui: ^baldr.Ui(Msg)) {
	baldr.column(ui, flex = 1, gap = .lg, padding = .xxl, align = .Center, justify = .Center); defer baldr.end(ui)
	baldr.text(ui, "How was it?", role = .Headline)
	n := baldr.custom(ui, stars, s, width = STARS * STAR + (STARS - 1) * GAP, height = STAR + 4,
		label = "Rating", role = .Slider, focusable = true,
		keys = {.Left, .Right, .Home, .End}, on_key = on_key)
	baldr.clickable(ui, n, Msg(Rate{}), label = "Rating")
	baldr.pointer_track(ui, n, on_hover)
	baldr.set_describe(&ui.tree, n, fmt.tprintf("%d of %d stars", s.rating, STARS)) // the value a reader says
	baldr.text(ui, fmt.tprintf("%d of %d", s.rating, STARS) if s.rating > 0 else "Not rated yet", muted = true)
}

main :: proc() {
	err := baldr.run(baldr.App(State, Msg){
		title  = "Custom widget",
		app_id = "baldr.custom",
		size   = {420, 260},
		update = update,
		view   = view,
	})
	if err != .None do fmt.eprintln("exit:", err)
}
