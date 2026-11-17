package baldr

// Scroll on a control: a wheel or touchpad scroll over a
// button that listens for it (`on_scroll`: a tray icon's Scroll, a volume
// applet, a workspace switcher) goes to it instead of to a scroll view
// around it, and focus stays where it is.

import "baldr:platform"

// Scroll is a wheel or touchpad scroll over a control. `steps` are whole
// wheel clicks along each axis, +y when the wheel turns down (the way
// content would move up), a touchpad's smooth motion adding up to a step
// every SCROLL_STEP_PX; `delta` is this event's logical px; `precise` says
// it came from a touchpad; `mods` are the modifiers held (Shift turns a
// vertical wheel sideways before it arrives); `pos` is where the pointer is
// over the node that took it, from its top-left (a zoom about the pointer).
Scroll :: struct {
	steps:   [2]int,
	delta:   [2]f32,
	precise: bool,
	mods:    Mods,
	pos:     [2]f32,
}

// SCROLL_STEP_PX is how far a touchpad moves for one wheel step.
SCROLL_STEP_PX :: platform.SCROLL_STEP_PX

// Scroll_Use is a control's scroll handler and the part of a step its
// smooth scrolling has built up.
@(private)
Scroll_Use :: struct($Msg: typeid) {
	handler: Handler(Msg, Scroll),
	rest:    [2]f32,
}

// scroll_send gives a scroll at `pos` to the innermost node with on_scroll
// (a disabled one passes it on to what is around it). Returns whether one
// took it.
@(private)
scroll_send :: proc(ui: ^Ui($Msg), pos, delta: [2]f32, precise: bool, mods: Mods) -> bool {
	t := &ui.tree
	for cur := hit_test(t, pos); cur != NODE_NONE; cur = node_parent(t, cur) {
		use, listens := &ui.on_scroll[cur]
		if !listens do continue
		d := node_get(t, cur)
		if .Disabled in d.flags do return false
		use.rest += delta
		steps: [2]int
		for i in 0 ..< 2 {
			whole := int(use.rest[i] / SCROLL_STEP_PX)
			steps[i] = whole
			use.rest[i] -= f32(whole) * SCROLL_STEP_PX
		}
		return handler_send(ui, use.handler, Scroll{steps = steps, delta = delta, precise = precise, mods = mods, pos = pos - {d.abs.x, d.abs.y}}, cur)
	}
	return false
}
