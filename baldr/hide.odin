package baldr

// Hiding at the edge: a layer surface that slides off its screen edge while
// hidden (autohide, intellihide).

import "core:fmt"
import "baldr:platform"

// HIDE_DELAY_MS is how long after the pointer leaves a surface it hides;
// HIDE_STRIP the logical px along its edge that reveal it; HIDE_SLIDE_MS how
// long its slide takes.
HIDE_DELAY_MS :: f32(400)
HIDE_STRIP    :: f32(2)
HIDE_SLIDE_MS :: f32(180)

// Hide_State is where the pointer and the keyboard are for a surface that
// hides: on it or on one of its popups.
@(private)
Hide_State :: struct {
	pointer_on: platform.Surface, // the surface of its own the pointer is on (0: none)
	focus_on:   platform.Surface, // …and the one with the keyboard (0: none)
	// …and the one a drag is over. A compositor drag brings no
	// wl_pointer.enter, so without this a hidden dock stays hidden under a
	// file dragged to it. Kept apart from `pointer_on` so a drag that ends
	// without a leave cannot hold the surface open.
	drag_on:    platform.Surface,
	left_ms:    f64,              // when the pointer last left them all (or it opened)
}

// hide_decide says whether a surface that hides shows now, and when to look
// again (0: nothing pending): shown while the pointer is on it, a popover is
// open on it or it has the keyboard; otherwise hidden `delay_ms` after the
// pointer left, when it hides Always or Overlap is covered.
@(private)
hide_decide :: proc "contextless" (h: Layer_Hide, pointer_on, popover_open, focused: bool, left_ms, now_ms: f64) -> (shown: bool, wake_ms: f64) {
	// `pointer_on` is "the pointer or a drag is on it": a drag reaching
	// the edge reveals the bar exactly as the pointer does.
	if h.mode == .Never || pointer_on || popover_open || focused do return true, 0
	if h.mode == .Overlap && !h.covered do return true, 0
	due := left_ms + f64(h.delay_ms if h.delay_ms > 0 else HIDE_DELAY_MS)
	if now_ms < due do return true, due
	return false, 0
}

// hide_offset is how far a surface's drawing has slid towards `edge`: `k` of
// its thickness (0 shown, 1 hidden).
@(private)
hide_offset :: proc "contextless" (edge: Edge, size: [2]f32, k: f32) -> [2]f32 {
	switch edge {
	case .Top:    return {0, -size.y * k}
	case .Bottom: return {0, size.y * k}
	case .Left:   return {-size.x * k, 0}
	case .Right:  return {size.x * k, 0}
	}
	return {}
}

// hide_strip is the strip along `edge` that takes the pointer while the
// surface is hidden.
@(private)
hide_strip :: proc "contextless" (edge: Edge, size: [2]f32, strip: f32) -> [4]f32 {
	s := min(strip if strip > 0 else HIDE_STRIP, size.x, size.y)
	switch edge {
	case .Top:    return {0, 0, size.x, s}
	case .Bottom: return {0, size.y - s, size.x, s}
	case .Left:   return {0, 0, s, size.y}
	case .Right:  return {size.x - s, 0, s, size.y}
	}
	return {}
}

// hide_held says whether anything is holding the surface open: the
// pointer on it, or a drag over it. Both have to go before the delay
// starts, since a drag usually arrives while the pointer is there.
@(private)
hide_held :: proc "contextless" (st: Hide_State) -> bool {
	return st.pointer_on != 0 || st.drag_on != 0
}

// hide_left_st: `who` (the pointer or a drag) left surface `s`. Pure, over
// the state alone, so the awkward cases can be tested without a window.
@(private)
hide_left_st :: proc(st: ^Hide_State, s: platform.Surface, now_ms: f64, drag: bool) {
	held := &st.pointer_on if !drag else &st.drag_on
	if held^ == 0 do return
	// `s` of 0 means "wherever it was": a drag that ends is reported to
	// every window at once and names no surface, and a hold nothing will
	// ever clear would leave the bar out for good.
	if s != 0 && held^ != s do return
	held^ = 0
	if !hide_held(st^) do st.left_ms = now_ms // the delay runs from the last one gone
}

// hide_pointer_left: the pointer left surface `s`.
@(private)
hide_pointer_left :: proc(c: ^Surface_Ctx($Msg), s: platform.Surface, now_ms: f64) {
	hide_left_st(&c.hide_st, s, now_ms, drag = false)
}

// hide_drag_over: a drag the desktop carries came over surface `s`, which
// holds a hiding surface open just as the pointer does.
@(private)
hide_drag_over :: proc(c: ^Surface_Ctx($Msg), s: platform.Surface) {
	c.hide_st.drag_on = s
}

// hide_drag_left: the drag went away from surface `s` — it left, it was
// dropped, or it ended somewhere else entirely. The delay runs from here,
// so the bar stays up for a moment as it does after the pointer leaves.
@(private)
hide_drag_left :: proc(c: ^Surface_Ctx($Msg), s: platform.Surface, now_ms: f64) {
	hide_left_st(&c.hide_st, s, now_ms, drag = true)
}

// hide_surface_closed: surface `s` of its own went away (a popup closing).
// Whatever it held — the pointer, the keyboard — it holds no longer, so a
// compositor that sends no leave for a surface it destroyed cannot leave a
// hiding surface shown for ever.
@(private)
hide_surface_closed :: proc(c: ^Surface_Ctx($Msg), s: platform.Surface, now_ms: f64) {
	hide_pointer_left(c, s, now_ms)
	hide_drag_left(c, s, now_ms)
	if c.hide_st.focus_on == s do c.hide_st.focus_on = 0
}

// hide_sync decides, once a wake-up, whether a surface that hides shows,
// asking for the frame a change needs and the wake-up its delay ends at.
@(private)
hide_sync :: proc(c: ^Surface_Ctx($Msg), now_ms: f64) {
	h := c.desc.hide
	edge, on_edge := layer_edge(c.desc.layer).?
	if c.kind != .Layer || !on_edge do h.mode = .Never
	c.fc.hide, c.fc.hide_edge = h, edge
	c.fc.blur_whole = c.ui.surface.glass && c.desc.backdrop == .Blur && c.desc.backdrop_region == .All
	if h.mode == .Never && !c.fc.hidden do return
	if t := &c.ui.tree; t.wake_at_ms > 0 && now_ms >= t.wake_at_ms do c.needs_frame = true // a due wake-up: the frame fires its timers
	popover_open := len(c.ui.dismiss) > 0 || len(c.popups) > 0
	pointer_on, focus_on := hide_held(c.hide_st), c.hide_st.focus_on != 0
	shown, wake := hide_decide(h, pointer_on, popover_open, focus_on, c.hide_st.left_ms, now_ms)
	if wake > 0 do tree_wake_at(&c.ui.tree, wake)
	if c.fc.hidden == !shown do return
	if c.fc.debug {
		fmt.eprintfln("baldr/events: surface %d %s: %v, covered %v, the pointer on it %v, a popover open %v, the keyboard in it %v",
			c.surf, "shown" if shown else "hidden", h.mode, h.covered, pointer_on, popover_open, focus_on)
	}
	c.fc.hidden = !shown
	c.fc.input_sent_ok = false // its strip, or where it takes the pointer as declared
	c.needs_frame = true
}

// hide_frame eases how far a surface that hides has slid, for this frame,
// presenting all of it while that moves. Instant under reduce-motion.
@(private)
hide_frame :: proc(fc: ^Frame_Ctx) {
	if fc.hide.mode == .Never && !fc.hidden && fc.slide == {} do return
	k := anim_target(fc.tree, fc.tree.root, .Hide, 1 if fc.hidden else 0, HIDE_SLIDE_MS, .Ease_In_Out)
	slide := hide_offset(fc.hide_edge, fc.size, k)
	if slide == fc.slide do return
	fc.slide = slide
	fc.present_whole = true
}

// hide_at_edge: the surface is hidden and fully slid out, so it can sit at
// the screen's own edge (its margin goes, and comes back as it slides out).
@(private)
hide_at_edge :: proc "contextless" (fc: ^Frame_Ctx) -> bool {
	if fc.hide.mode == .Never || !fc.hidden do return false
	return fc.slide == hide_offset(fc.hide_edge, fc.size, 1)
}

// hide_place_sync moves a hiding surface to the screen's edge once it is
// out of sight, and back to the margin it declares as it comes out, with one
// placement request each way.
@(private)
hide_place_sync :: proc(c: ^Surface_Ctx($Msg), b: ^platform.Backend) {
	if c.kind != .Layer || c.desc.hide.mode == .Never || b == nil || b.surface_set_layer == nil do return
	want := hide_at_edge(&c.fc)
	if want == c.fc.hide_placed do return
	c.fc.hide_placed = want
	b.surface_set_layer(b, c.surf, layer_placed(c.desc, want), layer_size(&c.fc))
	if c.fc.debug do fmt.eprintfln("baldr/events: surface %d %s", c.surf, "at the screen's edge while hidden" if want else "back to its margin")
}

// hide_blur_sync narrows a whole-surface blur to where a surface that hides
// has slid, and gives it the whole surface again once it is back.
@(private)
hide_blur_sync :: proc(fc: ^Frame_Ctx) {
	b := fc.backend
	if !fc.blur_whole || b == nil do return
	if fc.slide == {} {
		if fc.blur_slid != {} && b.surface_set_backdrop != nil {
			b.surface_set_backdrop(b, fc.surface, .Blur) // the whole surface again
			fc.blur_slid = {}
		}
		return
	}
	x0, y0 := max(fc.slide.x, 0), max(fc.slide.y, 0)
	x1, y1 := min(fc.slide.x + fc.size.x, fc.size.x), min(fc.slide.y + fc.size.y, fc.size.y)
	r := [4]f32{x0, y0, max(x1 - x0, 0), max(y1 - y0, 0)}
	if r == fc.blur_slid do return
	b.surface_set_blur_region(b, fc.surface, {r}, {fc.shape_radius})
	fc.blur_slid = r
}

// layer_rect is where a layer surface of `size` shows on a screen of
// `screen` logical px, from its anchors and margins.
@(private)
layer_rect :: proc "contextless" (l: Layer_Desc, size, screen: [2]f32) -> Rect {
	r := Rect{w = size.x, h = size.y}
	switch {
	case .Left in l.anchor:  r.x = f32(l.margin[3])
	case .Right in l.anchor: r.x = screen.x - f32(l.margin[1]) - size.x
	case:                    r.x = (screen.x - size.x) / 2
	}
	switch {
	case .Top in l.anchor:    r.y = f32(l.margin[0])
	case .Bottom in l.anchor: r.y = screen.y - f32(l.margin[2]) - size.y
	case:                     r.y = (screen.y - size.y) / 2
	}
	return r
}

// Known_Surface is where one of the app's layer surfaces shows (surface_rect).
@(private)
Known_Surface :: struct {
	tag:    u64,
	rect:   Rect,
	output: string,
}

@(private, thread_local)
known_surfaces: [dynamic]Known_Surface

// surface_rect is where the layer surface tagged `tag` shows on its screen:
// its rectangle in logical px from the screen's top-left, where it shows even
// while it hides, and the screen's name, as of the latest wake-up (a FIT
// dock's length once laid out); `output` aliases the toolkit's own list of
// screens, so copy it to hold it past a screen change. False for a window,
// an applet, or a surface not yet on a known screen. An app hiding a
// surface on Overlap compares it with the compositor's windows for
// `covered`.
surface_rect :: proc(tag: u64) -> (rect: Rect, output: string, ok: bool) {
	for s in known_surfaces do if s.tag == tag do return s.rect, s.output, true
	return
}

// surfaces_known notes where each layer surface shows, for surface_rect.
@(private)
surfaces_known :: proc(rt: ^Runtime($State, $Msg)) {
	clear(&known_surfaces)
	for c in rt.ctxs {
		if c.kind != .Layer || c.output == "" || c.fc.size.x <= 0 || c.fc.size.y <= 0 do continue
		for o in known_outputs {
			if o.name != c.output do continue
			append(&known_surfaces, Known_Surface{tag = c.desc.tag, rect = layer_rect(c.desc.layer, c.fc.size, {f32(o.size.x), f32(o.size.y)}), output = o.name})
			break
		}
	}
}
