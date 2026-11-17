package baldr

// Pointer tracking: where the pointer is over a node as it moves.

// Pointer_At is where the pointer is over a node that tracks it: `pos` from
// the node's top-left, the node's `size`, whether the pointer is `inside` it
// (or anything in it), and whether a button pressed over it is still `held`
// — and while it is, `press`, where that press was over it. Reports come at
// most once a frame, so the press and the first moves can arrive as one
// report already moved; a drag goes by `pos - press` and loses none of its
// start. `buttons` is which buttons hold it, so a node with a menu can tell
// a right press from a left one; it is empty when none is down, and `held`
// is `buttons != {}`.
Pointer_At :: struct {
	pos, size: [2]f32,
	inside:    bool,
	held:      bool,
	buttons:   bit_set[Mouse_Button], // which buttons are holding it; empty when none is
	press:     [2]f32,
}

// Track is a tracking node's handler and what it has noted since it last
// reported.
@(private)
Track :: struct($Msg: typeid) {
	handler: Handler(Msg, Pointer_At),
	inside:  bool, // the pointer is over it
	held:    bool, // a button pressed over it is still down: it goes on hearing the pointer anywhere
	only:    bit_set[Mouse_Button], // the buttons it answers at all; {} is every button
	pending: bool, // something to report on the next tick
	at:      Pointer_At,
}

// pointer_track makes `n` report where the pointer is over it through
// `on_hover`: at most once a frame while the pointer moves over it or
// anything inside it, then once with `inside` false when the pointer leaves
// it or the surface, or the node goes away. While a button pressed over it
// is held, it goes on reporting until the release, outside it too, with
// `held` set. Unlike hoverable, it also hears the pointer arriving without
// a move (given back after a grab, or a surface appearing under it).
// Nothing is reported that it already knew. nil stops it. `buttons` is
// which buttons may hold it: `{}`, the default, is any; `{.Left}` makes a
// right or middle press neither hold it nor report, which a node that also
// has a `context_area` wants, since a menu's press is not a drag's start.
// What is held is reported in `Pointer_At.buttons` either way.
//
//	baldr.pointer_track(ui, shelf, proc(e: baldr.Ev(baldr.Pointer_At)) -> Msg { return Dock_Pointer{e.value.pos.x, e.value.inside} })
pointer_track :: proc(ui: ^Ui($Msg), n: Node, on_hover: Handler(Msg, Pointer_At), buttons: bit_set[Mouse_Button] = {}) {
	if node_get(&ui.tree, n) == nil do return
	if !handler_live(on_hover) { // not `== nil`: see handler_live
		delete_key(&ui.tracks, n)
		return
	}
	if tr, ok := &ui.tracks[n]; ok {
		tr.handler = on_hover
		tr.only = buttons
		return
	}
	ui.tracks[n] = Track(Msg){handler = on_hover, only = buttons}
}

// track_move: the pointer moved to `pos`. The tracking nodes it is over, or
// that a press on them holds, note where it is; one it just left notes that.
@(private)
track_move :: proc(ui: ^Ui($Msg), pos: [2]f32) {
	if len(ui.tracks) == 0 do return
	t := &ui.tree
	hit := hit_test(t, pos)
	for n, &tr in ui.tracks {
		d := node_get(t, n)
		if d == nil do continue
		over := false
		for cur := hit; cur != NODE_NONE; cur = node_parent(t, cur) {
			if cur == n {
				over = true
				break
			}
		}
		if !over && !tr.inside && !tr.held do continue // elsewhere, as it was
		at := Pointer_At{pos = pos - {d.abs.x, d.abs.y}, size = {d.abs.w, d.abs.h}, inside = over, held = tr.held, buttons = tr.at.buttons, press = tr.at.press}
		if at == tr.at do continue // the pointer given back where it already was: nothing new to say
		tr.inside = over
		tr.at = at
		tr.pending = true
	}
}

// track_button: a press at `pos` over a tracking node holds it, so it goes
// on hearing the pointer until the release, and notes which button and
// where it was; the last release lets it go. The held buttons are a set, so
// a second button's release mid-drag does not let go of the first.
@(private)
track_button :: proc(ui: ^Ui($Msg), button: Mouse_Button, pressed: bool, pos: [2]f32) {
	for n, &tr in ui.tracks {
		if tr.only != {} && button not_in tr.only do continue
		if pressed && !tr.inside do continue
		was := tr.at.buttons
		if pressed { tr.at.buttons += {button} } else { tr.at.buttons -= {button} }
		if tr.at.buttons == was do continue
		tr.held = tr.at.buttons != {}
		tr.at.held, tr.at.inside = tr.held, tr.inside
		if was == {} && tr.held { // the first button down: where the press was
			if d := node_get(&ui.tree, n); d != nil do tr.at.press = pos - {d.abs.x, d.abs.y}
		}
		tr.pending = true
	}
}

// track_leave: the pointer left the surface.
@(private)
track_leave :: proc(ui: ^Ui($Msg)) {
	for _, &tr in ui.tracks {
		if !tr.inside && !tr.held do continue
		tr.inside, tr.held = false, false
		tr.at.inside, tr.at.held, tr.at.buttons = false, false, {}
		tr.pending = true
	}
}

// track_tick reports what each tracking node noted since the last tick: one
// message a frame however often the pointer moved.
@(private)
track_tick :: proc(ui: ^Ui($Msg)) {
	for n, &tr in ui.tracks {
		if !tr.pending do continue
		tr.pending = false
		handler_send(ui, tr.handler, tr.at, n)
	}
}

// track_forget is node `n` going away: if the pointer was over it, or a press
// held it, it hears `inside` false.
@(private)
track_forget :: proc(ui: ^Ui($Msg), n: Node) {
	tr, ok := ui.tracks[n]
	if !ok do return
	delete_key(&ui.tracks, n)
	if !tr.inside && !tr.held do return
	at := tr.at
	at.inside, at.held, at.buttons = false, false, {}
	handler_send(ui, tr.handler, at, n)
}
