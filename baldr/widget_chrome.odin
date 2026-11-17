package baldr

// A window's own title bar, for a window the desktop is not decorating
// (`Surface_Desc.undecorated`). A shell wants one; so does any app that puts
// something where the title would be — a browser's tabs, an editor's file
// name, a player's transport.
//
// What it must not be is a picture of a title bar. A real one moves the
// window when dragged, answers a double click as the desktop says, opens
// the desktop's own window menu on a right click, resizes from its edges,
// and has buttons a keyboard can reach and a screen reader can name. The
// move and the resize are the desktop's to run — the widget asks for them,
// carrying the serial of the press that asked, which is what stops a window
// seizing the pointer whenever it likes.
//
// It follows the desktop's choices for a title bar (Titlebar_Prefs): the
// buttons on the left or the right, which of minimise and maximise show,
// what a double click does, and whether the wheel rolls the window up to
// its bar, as the desktop's own title bars do. Rolled up,
// the window is only its bar: laid out at its full size still, so nothing
// in it moves, with what is below the bar out of reach of the pointer, the
// keyboard and assistive technology until it comes back down.

import "core:math"
import "baldr:platform"

@(private) CHROME_H      :: f32(36)
@(private) CHROME_BORDER :: f32(6)  // how far in from an edge a resize drag starts
@(private) CHROME_CORNER :: f32(16) // …and how far along it counts as a corner
@(private) CHROME_DOUBLE :: f64(400) // ms: two presses this close are a double click
@(private) CHROME_NOTCH  :: SCROLL_STEP_PX // wheel travel that rolls the window up or down

// Chrome_Button is one of the three a window offers.
Chrome_Button :: enum u8 { Minimize, Maximize, Close }
Chrome_Buttons :: bit_set[Chrome_Button; u8]

// CHROME_ALL is the usual set. A dialog often wants `{.Close}` alone.
CHROME_ALL :: Chrome_Buttons{.Minimize, .Maximize, .Close}

// Titlebar_Action is what a double click on a title bar the window draws
// itself does.
Titlebar_Action :: enum u8 {
	Maximize, // maximise, or restore: the usual
	Minimize,
	Roll_Up,  // roll the window up to its bar, or back down
	Menu,     // the desktop's window menu
	None,
}

// Titlebar_Wheel is what the wheel does over such a title bar: nothing, or
// (Roll_Up) up rolls the window up to its bar and down brings it back.
Titlebar_Wheel :: enum u8 { None, Roll_Up }

// Titlebar_Prefs are the desktop's choices for a title bar a window draws
// itself (window_chrome). `button_layout` is GNOME's button-layout: the
// buttons before the colon go on the left and those after it on the right,
// in that order — "close,minimize,maximize:" as on a Mac,
// ":minimize,maximize,close" the usual (and what "" means). A button left
// out is not shown, except close, which always is; other names (appmenu,
// icon, spacer) are not the window's and are passed over. The zero value is
// the usual in every way: buttons on the right, a double click maximising,
// the wheel doing nothing.
//
// A desktop that says (GNOME's settings, through the Settings portal) is
// followed by every window; an app that owns these settings passes them in
// `App.titlebar` and `set_titlebar_prefs` instead, as it does its
// accessibility preferences.
Titlebar_Prefs :: struct {
	button_layout: string,
	double_click:  Titlebar_Action,
	wheel:         Titlebar_Wheel,
}

// titlebar_action_of reads a double-click action as desktops write it:
// GNOME's action-double-click-titlebar ("toggle-maximize", "minimize",
// "toggle-shade", "menu", "none"; "lower" and the one-way maximises are the
// nearest there is) and a compositor's own config words ("maximize",
// "roll_up", "nothing"). False for a word it doesn't know.
titlebar_action_of :: proc(name: string) -> (Titlebar_Action, bool) {
	switch name {
	case "toggle-maximize", "toggle-maximize-horizontally", "toggle-maximize-vertically", "maximize": return .Maximize, true
	case "minimize":                                    return .Minimize, true
	case "toggle-shade", "shade", "roll_up", "roll-up": return .Roll_Up, true
	case "menu":                                        return .Menu, true
	case "none", "nothing", "lower":                    return .None, true
	}
	return .Maximize, false
}

// Chrome_Prefs are Titlebar_Prefs as a tree uses them: the layout read into
// the buttons at each end, left to right. `set` false is the usual.
@(private)
Chrome_Prefs :: struct {
	set:          bool,
	left, right:  [3]Chrome_Button,
	n_left:       u8,
	n_right:      u8,
	double_click: Titlebar_Action,
	wheel:        Titlebar_Wheel,
}

// CHROME_USUAL is the title bar with nothing said: minimise, maximise and
// close on the right.
@(private)
CHROME_USUAL :: Chrome_Prefs{set = true, right = {.Minimize, .Maximize, .Close}, n_right = 3}

// chrome_prefs reads Titlebar_Prefs, GNOME's layout string with them.
@(private)
chrome_prefs :: proc(p: Titlebar_Prefs) -> (out: Chrome_Prefs) {
	out = CHROME_USUAL
	out.double_click, out.wheel = p.double_click, p.wheel
	if p.button_layout == "" do return
	out.n_left, out.n_right = 0, 0
	right := false
	seen: Chrome_Buttons
	start := 0
	for i := 0; i <= len(p.button_layout); i += 1 {
		end := i == len(p.button_layout)
		if !end && p.button_layout[i] != ',' && p.button_layout[i] != ':' do continue
		b: Chrome_Button
		ok := true
		switch p.button_layout[start:i] {
		case "close":    b = .Close
		case "minimize": b = .Minimize
		case "maximize": b = .Maximize
		case:            ok = false // appmenu, icon, spacer: not the window's
		}
		if ok && b not_in seen {
			seen += {b}
			if right {
				out.right[out.n_right] = b
				out.n_right += 1
			} else {
				out.left[out.n_left] = b
				out.n_left += 1
			}
		}
		if !end && p.button_layout[i] == ':' do right = true
		start = i + 1
	}
	if .Close not_in seen { // a window can always be closed
		out.right[out.n_right] = .Close
		out.n_right += 1
	}
	return
}

// set_titlebar_prefs gives this tree's title bars the choices `p` says,
// for a desktop that owns them and would rather say than be asked (the app
// reads its own settings): once set, the desktop's leave this tree alone,
// as with set_a11y_prefs. `App.titlebar` says it for every surface at
// start-up. Call it before the view builds its title bar, or it shows in
// the next build.
set_titlebar_prefs :: proc(t: ^Tree, p: Titlebar_Prefs) {
	t.titlebar_app = true
	t.titlebar = chrome_prefs(p)
}

// chrome_prefs_of is what a tree's title bars follow now.
@(private)
chrome_prefs_of :: proc(t: ^Tree) -> Chrome_Prefs {
	return t.titlebar if t.titlebar.set else CHROME_USUAL
}

// Chrome_State marks the bar and remembers the last press on it, for the
// double click.
@(private)
Chrome_State :: struct {
	last_press: f64, // CHROME_NO_PRESS until there has been one: a fresh bar's
	                 // first press is not a double click against a clock at zero
	ink:        Color, // what its title and buttons are drawn in (zero: the theme's) — a note's bar is its own paper
	start:      Node, // where buttons on the left go (NODE_NONE when none do)
	wheel:      f32,  // wheel travel over it not yet a notch (a touchpad's small steps)
}

@(private) CHROME_NO_PRESS :: f64(-1e9)

// window_chrome opens a title bar across the top of an undecorated window —
// a row with the title in it, which stays open so the app can build its own
// controls into the same bar. Close it with `end`, and put the window's own
// buttons in with `window_buttons` before you do.
//
// Dragging the bar moves the window, a double click maximises or restores
// it (or what the desktop says: minimises, rolls it up, opens the window
// menu, nothing), and a right click opens the desktop's own window menu;
// the wheel rolls it up and down where the desktop says so. The window's
// resize edges come with it: an undecorated window has to catch the pointer
// near its own borders, or it cannot be resized at all.
//
//	baldr.window_chrome(ui, "Notes"); {
//		defer baldr.end(ui)
//		baldr.window_buttons(ui, on_close = Msg(Quit{}))
//	}
window_chrome :: proc(ui: ^Ui($Msg), title: string, ink: Maybe(Color) = nil, key: u64 = 0, loc := #caller_location) -> Node {
	t := &ui.tree
	bar := row(ui, gap = .xs, padding = .xs, align = .Center, height = CHROME_H, key = key, loc = loc)
	if d := node_get(t, bar); d != nil {
		d.access.role = .Toolbar
		set_name(t, bar, title if title != "" else "Title bar")
	}
	st, had := &t.chrome[bar]
	if !had {
		t.chrome[bar] = Chrome_State{last_press = CHROME_NO_PRESS}
		st = &t.chrome[bar]
	}
	// A bar on a colour the app chose needs the app's ink: the theme's may
	// vanish against it. It stays until changed, as an editor's does.
	if v, ok := ink.?; ok do st.ink = v
	// Rolled up, the bar says so: the window's content is collapsed into it.
	if d := node_get(t, bar); d != nil {
		if ui.surface.rolled { d.access.states += {.Collapsed} } else { d.access.states -= {.Collapsed} }
	}

	// Buttons the desktop puts on the left go before the title: a place kept
	// for them here, filled by window_buttons once the app has said which.
	start := NODE_NONE
	if chrome_prefs_of(t).n_left > 0 {
		start = row(ui, gap = .xxs, align = .Center, key = 6)
		end(ui)
	}
	if s := &t.chrome[bar]; s != nil do s.start = start
	text(ui, title, role = .Label, nowrap = true, ellipsis = .End, color = chrome_ink(t, bar), key = 1)
	spacer(ui, key = 2)
	return bar
}

// chrome_ink is what a title bar writes in: the colour the app gave it,
// else the theme's text colour.
@(private)
chrome_ink :: proc(t: ^Tree, bar: Node) -> Color {
	if st, ok := t.chrome[bar]; ok && st.ink.a > 0 do return st.ink
	return t.theme.color.on_surface
}

// window_buttons puts the window's own buttons in the bar, where the
// desktop wants them: at its end, or before the title (Titlebar_Prefs),
// in the desktop's order. Call it after whatever the app builds into the
// bar, so its controls sit beside the title rather than past the close
// button. An app with nothing of its own calls the two back to back.
// `buttons` are the ones the window offers (a dialog: `{.Close}`); of those,
// the desktop's layout says which of minimise and maximise show. Close
// always does.
//
//	baldr.window_chrome(ui, "Notes"); {
//		defer baldr.end(ui)
//		tabs(ui, s)                                   // the app's own
//		baldr.window_buttons(ui, on_close = Msg(Quit{}))   // …and the window's
//	}
window_buttons :: proc(ui: ^Ui($Msg), buttons: Chrome_Buttons = CHROME_ALL, on_close: Maybe(Msg) = nil, ink: Maybe(Color) = nil, loc := #caller_location) {
	t := &ui.tree
	bar := ui.scopes[len(ui.scopes) - 1].node if len(ui.scopes) > 0 else NODE_NONE
	st, is_bar := t.chrome[bar]
	if !is_bar do return // not in a title bar: nothing to put buttons on
	if m, has := on_close.?; has do ui.chrome_close[bar] = m
	if v, ok := ink.?; ok { // the buttons sit on the same paper as the title
		st.ink = v
		t.chrome[bar] = st
	}
	// The buttons are the desktop's business, not the app's, so they send no
	// message and act through the same path the pointer does. They are still
	// real objects: focusable, named, and reachable by keyboard.
	p := chrome_prefs_of(t)
	put :: proc(ui: ^Ui($Msg), bar: Node, b: Chrome_Button) {
		n := chrome_button(ui, bar, b, u64(b) + 3)
		ui.tree.chrome_btn[n] = b
		ui.tree.chrome_of[n] = bar
	}
	if st.start != NODE_NONE { // the left: into the place window_chrome kept before the title
		open_scope(ui, st.start, loc)
		for b in p.left[:p.n_left] do if b in buttons do put(ui, bar, b)
		close_scope(ui)
	}
	for b in p.right[:p.n_right] do if b in buttons do put(ui, bar, b)
}

// chrome_button is one of the window's own buttons: a box with an icon,
// focusable and named, activated through `click` so a pointer press and an
// Enter are the same path. It sends the app nothing — what it does is the
// desktop's business.
@(private)
chrome_button :: proc(ui: ^Ui($Msg), bar: Node, b: Chrome_Button, key: u64) -> Node {
	t := &ui.tree
	th := &t.theme
	maximised := ui.surface.maximized
	which: Icon
	name: string
	switch b {
	case .Minimize: which, name = .Minus, "Minimise"
	case .Maximize:
		which = .Copy if maximised else .Square
		name  = "Restore" if maximised else "Maximise"
	case .Close:    which, name = .X, "Close"
	}
	glyph := chrome_ink(t, bar)
	glyph.a *= 0.75 // a window's own buttons sit back from its title, as the theme's muted text does
	n := row(ui, align = .Center, justify = .Center, width = CHROME_H - 8, height = CHROME_H - 8, radius = th.radius.sm, key = key)
	icon(ui, which, size = th.type.caption.size + 2, color = glyph)
	end(ui)
	if d := node_get(t, n); d != nil {
		d.flags += {.Focusable}
		d.access.role = .Button
		set_name(t, n, name)
	}
	return n
}

// ------------------------------------------------------------ acting

// chrome_act does what a button says, or what a gesture on the bar asked
// for. Everything here is a request to the desktop: it decides.
@(private)
chrome_act :: proc(ui: ^Ui($Msg), bar: Node, act: platform.Window_Act, edges: platform.Window_Edges = {}, at: [2]f32 = {}) -> bool {
	h := ui.tree.window
	if h.act == nil do return false
	return h.act(h.user, h.surface, act, edges, at)
}

// chrome_click is `click` reaching one of the window's own buttons.
@(private)
chrome_click :: proc(ui: ^Ui($Msg), n: Node) -> bool {
	t := &ui.tree
	b, is_btn := t.chrome_btn[n]
	if !is_btn do return false
	bar := t.chrome_of[n]
	switch b {
	case .Minimize:
		return chrome_act(ui, bar, .Minimize)
	case .Maximize:
		return chrome_maximize(ui, bar)
	case .Close:
		if m, has := ui.chrome_close[bar]; has { // the app asked to be told
			append(&ui.msgs, m)
			return true
		}
		// …otherwise the window goes, exactly as if the desktop had asked:
		// the run loop decides what closing means, as it does for the
		// compositor's own close
		h := ui.tree.window
		if h.close != nil do h.close(h.user, h.surface)
		return true
	}
	return false
}

// chrome_maximize maximises the window or restores it; one rolled up comes
// down first, so it is the whole window that fills the screen.
@(private)
chrome_maximize :: proc(ui: ^Ui($Msg), bar: Node) -> bool {
	if ui.surface.maximized do return chrome_act(ui, bar, .Unmaximize)
	if ui.surface.rolled do chrome_roll(ui, bar, false)
	return chrome_act(ui, bar, .Maximize)
}

// chrome_press is a press on the bar itself: a drag moves the window, a
// second press in quick succession does what the desktop says a double
// click does, and the right button asks the desktop for its window menu.
@(private)
chrome_press :: proc(ui: ^Ui($Msg), pos: [2]f32, button: Mouse_Button) -> bool {
	t := &ui.tree
	// Asked by position, not by the hover target: a title bar is a plain row
	// and the hover only tracks what can be interacted with, so a bar would
	// never be "under" the pointer at all.
	bar := chrome_bar_at(ui, pos)
	if bar == NODE_NONE do return false
	st := &t.chrome[bar]
	d := node_get(t, bar)
	at := pos - {d.abs.x, d.abs.y} if d != nil else pos
	if button == .Right do return chrome_act(ui, bar, .Menu, {}, at)
	if button != .Left do return false
	now := t.now_ms
	double := now - st.last_press <= CHROME_DOUBLE
	st.last_press = now
	action := chrome_prefs_of(t).double_click
	if double && action != .None {
		st.last_press = CHROME_NO_PRESS // a third press is not another double
		switch action {
		case .Maximize: return chrome_maximize(ui, bar)
		case .Minimize: return chrome_act(ui, bar, .Minimize)
		case .Roll_Up:  return chrome_roll(ui, bar, !ui.surface.rolled)
		case .Menu:     return chrome_act(ui, bar, .Menu, {}, at)
		case .None:
		}
	}
	return chrome_act(ui, bar, .Move) // a double click that does nothing is still a press that can drag
}

// chrome_wheel is the wheel over a title bar: where the desktop says so,
// up rolls the window up to its bar and down brings it back, a notch at a
// time (a touchpad's small steps add up to one first). True when the bar
// took it.
@(private)
chrome_wheel :: proc(ui: ^Ui($Msg), pos: [2]f32, delta: [2]f32) -> bool {
	t := &ui.tree
	if chrome_prefs_of(t).wheel != .Roll_Up || delta.y == 0 do return false
	bar := chrome_bar_at(ui, pos)
	if bar == NODE_NONE do return false
	st := &t.chrome[bar]
	st.wheel += delta.y
	switch {
	case st.wheel <= -CHROME_NOTCH:
		st.wheel = 0
		chrome_roll(ui, bar, true)
	case st.wheel >= CHROME_NOTCH:
		st.wheel = 0
		chrome_roll(ui, bar, false)
	}
	return true
}

// chrome_roll rolls the window up to the bottom of its bar, or back down to
// the size it had. Never a window the desktop sizes (maximised, full screen,
// tiled), and never one that isn't a window.
@(private)
chrome_roll :: proc(ui: ^Ui($Msg), bar: Node, up: bool) -> bool {
	h := ui.tree.window
	if h.roll == nil || up == ui.surface.rolled do return false
	if up {
		if ui.surface.kind != .Window || ui.surface.maximized || ui.surface.fullscreen || ui.surface.tiled do return false
		d := node_get(&ui.tree, bar)
		if d == nil do return false
		ui.tree.roll_bar = bar
		return h.roll(h.user, h.surface, true, math.ceil(d.abs.y + d.abs.h))
	}
	return h.roll(h.user, h.surface, false, 0)
}

// roll_inert makes what a rolled-up window hides below its bar inert (no
// pointer, no keyboard, nothing for assistive technology), or gives it back.
// What is below: the siblings after the bar, and after each of its
// ancestors, in a column. Nodes the app made inert itself are left to it.
// Run after every build while rolled, for the nodes it made. Keyboard focus
// that was below goes to the bar's first control and comes back after.
@(private)
roll_inert :: proc(t: ^Tree, rolled: bool) {
	for n in t.roll_inert do if d := node_get(t, n); d != nil do d.flags -= {.Inert}
	clear(&t.roll_inert)
	if !rolled {
		if f := t.roll_focus; f != NODE_NONE && focusable(t, f) do set_focus(t, f, t.focus_visible)
		t.roll_focus = NODE_NONE
		return
	}
	bar := t.roll_bar
	if node_get(t, bar) == nil do return
	for child, p := bar, node_parent(t, bar); p != NODE_NONE; child, p = p, node_parent(t, p) {
		pd := node_get(t, p)
		if pd == nil || pd.layout.axis != .Column do continue
		for s := node_next(t, child); s != NODE_NONE; s = node_next(t, s) {
			sd := node_get(t, s)
			if sd == nil || sd.flags & {.Inert, .Overlay} != {} do continue
			focus_below := t.focus != NODE_NONE && node_within(t, t.focus, s)
			if focus_below && t.roll_focus == NODE_NONE do t.roll_focus = t.focus
			set_inert(t, s, true) // focus inside it moves up…
			append(&t.roll_inert, s)
			if focus_below do focus_first(t, bar, t.focus_visible) // …to the bar's first control
		}
	}
}

// chrome_bar_at is the title bar a point is on — and nothing when the point
// is on one of its buttons or on anything else that answers a press itself,
// because a control inside the bar is not a drag handle.
@(private)
chrome_bar_at :: proc(ui: ^Ui($Msg), pos: [2]f32) -> Node {
	t := &ui.tree
	for bar, _ in t.chrome {
		d := node_get(t, bar)
		if d == nil || d.flags & {.Hidden, .Inert} != {} do continue
		if !rect_contains(d.abs, pos) do continue
		// anything inside the bar that takes a press keeps it
		for n, _ in t.chrome_btn {
			if bd := node_get(t, n); bd != nil && rect_contains(bd.abs, pos) do return NODE_NONE
		}
		// …asked of the control the press belongs to, not of the innermost
		// node: a hit test on an icon-only button returns the icon, which
		// answers nothing, and the bar would take the press.
		if hit := hit_test(t, pos); hit != NODE_NONE && hit != bar {
			if target := interactive_target(ui, hit); target != NODE_NONE && target != bar do return NODE_NONE
		}
		return bar
	}
	return NODE_NONE
}

// ------------------------------------------------------------ the edges

// chrome_edge_at is the resize edge a point is on, for an undecorated
// window: within a few pixels of a border, and the corners reach further
// along so they are catchable.
@(private)
chrome_edge_at :: proc(size: [2]f32, pos: [2]f32) -> platform.Window_Edges {
	out: platform.Window_Edges
	if pos.x <= CHROME_BORDER do out += {.Left}
	if pos.x >= size.x - CHROME_BORDER do out += {.Right}
	if pos.y <= CHROME_BORDER do out += {.Top}
	if pos.y >= size.y - CHROME_BORDER do out += {.Bottom}
	// a corner is wider than the border it sits in, or it cannot be hit
	if out == {.Left} || out == {.Right} {
		if pos.y <= CHROME_CORNER do out += {.Top}
		if pos.y >= size.y - CHROME_CORNER do out += {.Bottom}
	} else if out == {.Top} || out == {.Bottom} {
		if pos.x <= CHROME_CORNER do out += {.Left}
		if pos.x >= size.x - CHROME_CORNER do out += {.Right}
	}
	return out
}

// chrome_resize_press starts a resize when the press was on a border of an
// undecorated window that has chrome. Returns true when the desktop took it.
@(private)
chrome_resize_press :: proc(ui: ^Ui($Msg), pos: [2]f32) -> bool {
	t := &ui.tree
	if len(t.chrome) == 0 do return false      // only a window that draws its own frame
	if ui.surface.maximized || ui.surface.fullscreen || t.rolled do return false // nothing to drag (rolled up: its size is its own until it comes down)
	edges := chrome_edge_at(t.viewport, pos)
	if edges == {} do return false
	bar := NODE_NONE
	for n, _ in t.chrome { bar = n; break }
	return chrome_act(ui, bar, .Resize, edges)
}

// chrome_cursor is what the pointer should look like near an edge, so the
// window says it can be resized before it is dragged.
@(private)
chrome_cursor :: proc(t: ^Tree, pos: [2]f32) -> (Cursor, bool) {
	if len(t.chrome) == 0 || t.rolled do return .Default, false
	edges := chrome_edge_at(t.viewport, pos)
	switch {
	case edges == {.Top} || edges == {.Bottom}: return .Resize_NS, true
	case edges == {.Left} || edges == {.Right}: return .Resize_EW, true
	case edges == {.Top, .Left} || edges == {.Bottom, .Right}: return .Resize_NWSE, true
	case edges == {.Top, .Right} || edges == {.Bottom, .Left}: return .Resize_NESW, true
	}
	return .Default, false
}

// Window_Hook is how a tree asks the desktop about its own frame: installed
// by the run loop, which owns the backend, and zero in a headless test —
// where every request simply fails, which is what a test should see.
Window_Hook :: struct {
	user:    rawptr,
	surface: u32,
	act:     proc(user: rawptr, surface: u32, act: platform.Window_Act, edges: platform.Window_Edges, at: [2]f32) -> bool,
	// close asks for this window to go as if the desktop had asked, so one
	// place decides what closing means (an app's own on_close, a last window
	// ending the run).
	close:   proc(user: rawptr, surface: u32),
	// roll rolls the window up to `height` (its bar's bottom), or back down
	// to the size it had. False when it can't.
	roll:    proc(user: rawptr, surface: u32, up: bool, height: f32) -> bool,
}
