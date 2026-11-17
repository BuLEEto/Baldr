package baldr

// What a view may know of the keyboard: which surface has it
// (`ui.surface.keyboard`), the lock keys that are on, and the active layout
// — a lock screen puts its password card where the keyboard is, says when
// Caps Lock is on, and names the layout the password will be typed in. Read
// in a view like the viewport; views are built again whenever any of it
// changes, with no message.

import "baldr:platform"

// Lock_Key is a key that stays on: Caps, Num.
Lock_Key  :: platform.Lock_Key
Lock_Keys :: platform.Lock_Keys

// Keyboard_Info is the keyboard as the views see it; the run loop keeps it
// current. `layout` is the run loop's.
@(private)
Keyboard_Info :: struct {
	locks:   Lock_Keys,
	layout:  string,
	layouts: int,
}

// keyboard_locks is the lock keys that are on now — Caps Lock, Num Lock —
// the locked ones, so a Caps Lock turned on before the view was shown
// counts. A password field shows Caps Lock of its own accord; a lock screen
// or a greeter may say it in words too.
//
//	if .Caps in baldr.keyboard_locks(ui) do baldr.text(ui, "Caps Lock is on", muted = true)
keyboard_locks :: proc(ui: ^Ui($Msg)) -> Lock_Keys {
	return ui.tree.keyboard.locks
}

// keyboard_layout is the active keyboard layout's name, as the desktop's
// keymap calls it ("English (UK)"; "" when it gives none), and how many
// layouts there are — a password prompt names the layout when there is
// more than one. The name is the toolkit's until the layout changes: copy
// it to keep it.
//
//	if name, n := baldr.keyboard_layout(ui); n > 1 do baldr.text(ui, name, muted = true)
keyboard_layout :: proc(ui: ^Ui($Msg)) -> (name: string, layouts: int) {
	return ui.tree.keyboard.layout, ui.tree.keyboard.layouts
}

// keyboard_event takes the keyboard's new state (Ev_Keyboard) to every
// surface and builds their views again.
@(private)
keyboard_event :: proc(rt: ^Runtime($State, $Msg), e: platform.Ev_Keyboard) {
	old := rt.keyboard.layout
	rt.keyboard = {locks = e.locks, layout = clone_string(e.layout), layouts = e.layouts}
	for c in rt.ctxs {
		c.ui.tree.keyboard = rt.keyboard
		ask_view(c)
	}
	delete(old)
}

// keyboard_focus notes which of a surface's own (it, or a popup of it) has
// the keyboard, and builds its view again when that changes whether it has.
//
// A panel gaining the keyboard with nothing focused lands on its first
// control, ring showing (`entered_keyboard`, applied when the view
// finishes), but only when no pointer press brought it there: a press
// decides focus by itself, and a ring after a press is what :focus-visible
// prevents. The landing is for a keyboard arriving with no pointer, where
// it is the only sign that it worked. A window is left alone: its keyboard
// follows the desktop's window focus, and moving the ring on every alt-tab
// would lose the place.
@(private)
keyboard_focus :: proc(c: ^Surface_Ctx($Msg), surface: platform.Surface, focused: bool) {
	if focused {
		c.hide_st.focus_on = surface
	} else if c.hide_st.focus_on == surface {
		c.hide_st.focus_on = 0
	}
	if has := c.hide_st.focus_on != 0; has != c.ui.surface.keyboard {
		c.ui.surface.keyboard = has
		tree_keyboard_set(&c.ui.tree, has) // the focus ring is drawn only while it is here
		// Unless the panel says not to: a full-screen overlay's keys are its
		// own while nothing is focused, and a ring would say "this is chosen".
		lands := c.kind == .Applet || c.desc.layer.keyboard_landing == .First_Control
		if has && (c.kind == .Layer || c.kind == .Applet) && lands && c.ui.tree.focus == NODE_NONE && !c.ui.pointer_took_focus {
			c.ui.entered_keyboard = true
		}
		ask_view(c)
	}
}

// keyboard_release tells the compositor this surface wants no keyboard, so
// that it hands it to whatever should have it next (panel_escape). On
// Wayland a client cannot give focus to another client; it can only say it
// does not want it. A `.Exclusive` layer surface keeps it: Escape must not
// be a way off a lock screen.
@(private)
keyboard_release :: proc(b: ^platform.Backend, c: ^Surface_Ctx($Msg)) {
	if b == nil || c.keyboard_dropped do return
	#partial switch c.kind {
	case .Layer:
		if c.desc.layer.keyboard != .On_Demand || b.surface_set_layer == nil do return
		l := layer_placed(c.desc)
		l.keyboard = .None
		if !b.surface_set_layer(b, c.surf, l, layer_size(&c.fc)) do return
	case .Applet:
		if c.desc.applet.keyboard != .On_Demand || b.surface_set_applet == nil do return
		a := c.desc.applet
		a.keyboard = .None
		if !b.surface_set_applet(b, c.surf, a) do return
	case:
		return
	}
	c.keyboard_dropped = true
	c.needs_frame = true // the next frame commits the wanting-it-again below
}

// keyboard_restore puts back what keyboard_release asked for, once a frame
// has gone by with the surface not wanting the keyboard.
//
// A frame apart on purpose: layer-shell state is applied on commit, so
// `.None` and `.On_Demand` in the same commit is only the second and focus
// would never leave. A frame is the smallest gap certain to be two commits,
// and the panel has already drawn itself without a ring.
@(private)
keyboard_restore :: proc(b: ^platform.Backend, c: ^Surface_Ctx($Msg)) {
	if b == nil || !c.keyboard_dropped do return
	c.keyboard_dropped = false
	#partial switch c.kind {
	case .Layer:
		if b.surface_set_layer != nil do b.surface_set_layer(b, c.surf, layer_placed(c.desc), layer_size(&c.fc))
	case .Applet:
		if b.surface_set_applet != nil do b.surface_set_applet(b, c.surf, c.desc.applet)
	}
}
