package baldr

// Keyboard focus. One focused node per tree; Tab / Shift+Tab walk the
// focusable nodes in tree order; Enter / Space activate. The focus ring is
// drawn only after keyboard navigation (`focus_visible`), never after a
// pointer press — the :focus-visible rule — and only while the surface
// actually has the keyboard (`ring_shown`).

import "core:fmt"

// ring_shown says whether a focus ring should be drawn at all: the keyboard
// put focus where it is, *and* this surface still has the keyboard.
//
// Focus itself survives the keyboard leaving, so Tab carries on from the same
// control when it comes back and assistive technology can still say where
// focus is. Only the drawing stops, as for a focused control in any inactive
// window; a ring left on a dock's button would read as "selected".
@(private)
ring_shown :: proc(t: ^Tree) -> bool {
	return t.focus_visible && t.keyboard_on
}

// tree_keyboard_set records whether this tree's surface has the keyboard, and
// repaints the focused control so its ring actually goes or comes back.
//
// The repaint matters: paint reuses a layer it was not told had changed, so
// without it the ring stays until something else dirties that node. The run
// loop's rebuild on a keyboard move would also cover it, but the ring should
// not depend on that.
tree_keyboard_set :: proc(t: ^Tree, on: bool) {
	if t.keyboard_on == on do return
	t.keyboard_on = on
	if t.focus != NODE_NONE do mark_paint_dirty(t, t.focus)
}

Key :: enum u16 {
	Unknown, Tab, Enter, Space, Escape, Left, Right, Up, Down, Home, End, Page_Up, Page_Down,
	Backspace, Delete, A, C, V, X, // text_input hook: editing and clipboard keys
	Menu, F10, // context menu (Menu key, Shift+F10)
	Z, Y,      // undo / redo (Ctrl+Z, Ctrl+Y, Ctrl+Shift+Z)
	F, G, H, Slash, F3, // code editor: find, go to line, replace, comment toggle, next match
	B, I, U, E, K, // rich text: bold, italic, underline, code, link
	// the rest of the keyboard, for shortcuts (shortcut.odin)
	D, J, L, M, N, O, P, Q, R, S, T, W,
	N0, N1, N2, N3, N4, N5, N6, N7, N8, N9,
	F1, F2, F4, F5, F6, F7, F8, F9, F11, F12,
	Insert, Minus, Equal, Comma, Period, Grave, Bracket_L, Bracket_R, Backslash, Semicolon, Apostrophe,
	F13, F14, F15, F16, F17, F18, F19, F20, F21, F22, F23, F24,
	// (the keypad keeps arriving as the key it doubles — KP_1 as N1,
	// KP_Enter as Enter — so a widget sees one of each; a capture tells
	// them apart by the keysym name, which is what a configuration file
	// writes anyway)
	// the modifiers as keys in their own right: a chord being pressed shows
	// them before its last key arrives (key_capture.odin)
	Shift_L, Shift_R, Ctrl_L, Ctrl_R, Alt_L, Alt_R, Super_L, Super_R,
	Caps_Lock, Num_Lock, Scroll_Lock, Print, Pause,
	// and the keys a laptop has beyond the typewriter, which desktops bind
	// by default — a shortcut that cannot name them cannot show or rebind
	// them
	Volume_Up, Volume_Down, Volume_Mute, Mic_Mute,
	Media_Play, Media_Pause, Media_Play_Pause, Media_Stop, Media_Prev, Media_Next,
	Media_Rewind, Media_Forward, Media_Record,
	Brightness_Up, Brightness_Down, Kbd_Brightness_Up, Kbd_Brightness_Down,
	Power, Sleep, Wake, Eject,
	Search, Home_Page, Mail, Calculator, Explorer, Favorites, Tools, Refresh,
	Browser_Back, Browser_Forward,
	Display_Switch, Touchpad_Toggle, Wlan, Bluetooth, Rf_Kill,
	// app.odin maps platform.Key onto this
}

Mod :: enum u8 { Shift, Ctrl, Alt, Super }
Mods :: bit_set[Mod; u8]

// focusable reports whether a node can take keyboard focus right now.
focusable :: proc(t: ^Tree, n: Node) -> bool {
	d := node_get(t, n)
	if d == nil || .Focusable not_in d.flags || .Disabled in d.flags do return false
	for cur := n; cur != NODE_NONE; cur = node_get(t, cur).parent {
		if node_get(t, cur).flags & {.Hidden, .Inert} != {} do return false
	}
	return true
}

// focus_ancestor is the nearest node at or above `n` that can take keyboard
// focus, or NODE_NONE when nothing above it can. A press asks: a click on a
// label inside a button focuses the button, and a click on something with no
// focusable ancestor at all — a canvas, a panel's background — focuses
// nothing, which is what takes focus *away* from wherever it was.
focus_ancestor :: proc(t: ^Tree, n: Node) -> Node {
	for cur := n; cur != NODE_NONE; {
		if focusable(t, cur) do return cur
		d := node_get(t, cur)
		if d == nil do break
		cur = d.parent
	}
	return NODE_NONE
}

// focus_from_pointer moves focus as a press should: to the nearest focusable
// node at or above `n`, or away from whatever had it when there is none —
// as a browser does when a click on the page blurs the field. A node that
// asked for `focus_on_click = false` keeps the keys where they are: Tab
// still reaches it, and Enter or Space still press it once it has focus.
// Clearing focus matters: otherwise Enter over a canvas would press the
// last button clicked instead of reaching the window's shortcuts.
focus_from_pointer :: proc(t: ^Tree, n: Node) {
	take := focus_ancestor(t, n)
	if take != NODE_NONE {
		if d := node_get(t, take); d != nil && .Keys_Only_Focus in d.flags do return
	}
	set_focus(t, take, false) // pointer focus never shows the ring
}

// focus_on_click_set says whether a press focuses `d`. False is GTK's
// `focus-on-click = false` and macOS's toolbar buttons: Tab still reaches
// it, and Enter or Space still press it once it has focus, but clicking it
// leaves the keys where they were. A tools column, a toolbar's zoom buttons
// and a player's transport want it, so that picking a tool with the pointer
// and then holding Space pans at once. `button` and `clickable` take it
// directly, since a tools column says it on every button; `button_options`
// takes it too, for one button among many.
@(private)
focus_on_click_set :: proc(t: ^Tree, d: ^Node_Data, on: bool) {
	if on {
		d.flags -= {.Keys_Only_Focus}
	} else {
		d.flags += {.Keys_Only_Focus}
	}
}

// set_focus moves focus to `n` (or clears it with NODE_NONE). `visible`
// says whether the ring should show. Returns true when anything changed. An
// editor's builder node stands for its text. A node that cannot take the
// keyboard is refused, and BALDR_DEBUG_EVENTS says so.
set_focus :: proc(t: ^Tree, n: Node, visible: bool) -> (changed: bool) {
	n := n
	if a, is_frame := t.area_of_frame[n]; is_frame do n = a
	if n != NODE_NONE && !focusable(t, n) {
		if t.debug_events {
			d := node_get(t, n)
			if d == nil {
				fmt.eprintfln("baldr/events: focus refused: node %v is gone", n)
			} else {
				fmt.eprintfln("baldr/events: focus refused: node %v (%v %q, built at %s) cannot take the keyboard", n, d.access.role, d.access.name, loc_text(d.loc))
			}
		}
		return false
	}
	if t.focus != n {
		if old := node_get(t, t.focus); old != nil {
			old.flags -= {.Focused}
			old.access.states -= {.Focused}
			mark_paint_dirty(t, t.focus)
		}
		if t.ime.node != NODE_NONE && t.ime.node != n do ime_clear(t) // a composition belongs to the field it started in
		reveals_touch(t, t.focus, n) // focus inside an owner reveals what it holds
		t.focus = n
		if d := node_get(t, n); d != nil {
			d.flags += {.Focused}
			d.access.states += {.Focused}
			mark_paint_dirty(t, n)
		}
		changed = true
	}
	if visible && n != NODE_NONE do scroll_into_view(t, n) // keyboard focus must be on screen
	if t.focus_visible != visible {
		t.focus_visible = visible
		if t.focus != NODE_NONE do mark_paint_dirty(t, t.focus)
		changed = true
	}
	// Keyboard navigation cannot be debugged without seeing where focus
	// went and whether the ring came with it: a control that is focused but
	// draws no ring looks exactly like one that was never focused.
	if changed && t.debug_events {
		if n == NODE_NONE {
			fmt.eprintfln("baldr/events: focus cleared")
		} else {
			d := node_get(t, n)
			fmt.eprintfln("baldr/events: focus → node %v (%v %q), ring %v", n, d.access.role, d.access.name, visible)
		}
	}
	return
}

// focus_next moves focus to the next (or previous) focusable node in tree
// order, wrapping around. Returns false when there is nothing to focus.
focus_next :: proc(t: ^Tree, backwards := false) -> bool {
	order := make([dynamic]Node, context.temp_allocator)
	if t.modal != NODE_NONE && node_valid(t, t.modal) {
		collect_focusable(t, t.modal, &order) // focus trap
	} else if t.keyboard_popup != NODE_NONE && node_valid(t, t.keyboard_popup) {
		// A popover on a surface of its own that has the keyboard keeps Tab
		// inside it, as a dialog does: its surface is where the typing goes,
		// so a ring on the bar behind would sit on a control the keys cannot
		// reach.
		collect_focusable(t, t.keyboard_popup, &order)
	} else {
		collect_focusable(t, t.root, &order)
		collect_focusable(t, t.overlay, &order) // open popovers come after the page
	}
	if len(order) == 0 do return false
	idx := -1
	for n, i in order do if n == t.focus { idx = i; break }
	next: int
	if idx < 0 {
		next = len(order) - 1 if backwards else 0
	} else {
		next = (idx + (len(order) - 1 if backwards else 1)) % len(order)
	}
	if order[next] == t.drag_source && len(order) > 1 { // a carried item is in the air: Tab passes over it
		next = (next + (len(order) - 1 if backwards else 1)) % len(order)
	}
	set_focus(t, order[next], true)
	return true
}

@(private)
collect_focusable :: proc(t: ^Tree, n: Node, out: ^[dynamic]Node) {
	d := node_get(t, n)
	if d == nil || d.flags & {.Hidden, .Exiting, .Inert} != {} do return
	// `.Pointer_Only_Focus` is focusable and is not a Tab stop: a press gives
	// it the keyboard so its own keys (Ctrl+C on a selection) work, and Tab
	// walks past it, so a list of selectable paragraphs is not dozens of stops.
	if .Focusable in d.flags && .Disabled not_in d.flags && .Pointer_Only_Focus not_in d.flags do append(out, n)
	for c := d.first; c != NODE_NONE; c = node_get(t, c).next do if .Tab_First in node_get(t, c).flags do collect_focusable(t, c, out) // parts over their earlier siblings first
	for c := d.first; c != NODE_NONE; c = node_get(t, c).next do if .Tab_First not_in node_get(t, c).flags do collect_focusable(t, c, out)
}

// key_event handles toolkit-level keys: Tab traversal and activation of the
// focused node. Returns true if the key was consumed.
key_event :: proc(ui: ^Ui($Msg), key: Key, pressed: bool, mods: Mods) -> (consumed: bool) {
	if !pressed do return false
	t := &ui.tree
	if drag_key(ui, key, mods) do return true // Ctrl+X / Ctrl+V / Escape around a keyboard drag
	if submenu_key(ui, key, mods) do return true // Right / Enter open a submenu row, Left / Escape leave its popup
	if menu_bar_key(ui, key, mods) do return true // F10, and arrows across a menu bar's titles / menus
	if number_key(ui, key, mods) do return true // Up / Down / Enter / Escape in a number field
	if picker_key(ui, key, mods) do return true // Enter / Escape in a colour picker's hex field
	if sel_scope_key(ui, key, mods) do return true // a selection across views: Ctrl+C copies the lot, Escape lets it go
	if md_view_key(ui, key, mods) do return true // a focused markdown view: Ctrl+A, Ctrl+C, Escape
	if styled_key(ui, key, mods) do return true // …and a focused styled paragraph: Ctrl+A, Ctrl+C
	if text_area_key(ui, key, mods) { // a focused text area sees keys first
		if .Shift in mods || (key == .A && .Ctrl in mods) do primary_mark(t, t.focus) // a selection the person made
		return true
	}
	if code_bar_key(ui, key, mods) do return true // Enter / Escape in a code editor's find or go-to field
	if rich_ctl_key(ui, key, mods) do return true // Enter / Escape in a rich editor's link field
	if text_input_key(ui, key, mods) { // text_input hook: the focused field sees keys first
		if .Shift in mods || (key == .A && .Ctrl in mods) do primary_mark(t, t.focus)
		return true
	}
	if !window_nav(key, mods) { // Alt+Left, Alt+Up …: Back and Up go past views and controls to the window
		if custom_key(ui, key, mods) do return true // a focused custom widget takes the keys it named
		if table_key(ui, key, mods) do return true // a focused table moves its cursor / selection; a focused header resizes / reorders
		if icon_view_key(ui, key, mods) do return true // a focused icon view moves its cursor across the grid
		if tree_key(ui, key, mods) do return true // a focused tree view moves its cursor, expands, collapses
		if split_key(ui, key, mods) do return true // a focused split divider moves
		if choice_key(ui, key, mods) do return true // a focused radio group / segmented control moves its pick
		if calendar_key(ui, key, mods) do return true // a focused date picker moves its cursor day
		if time_key(ui, key, mods) do return true // a focused time picker edits its picked segment
		if slider_key(ui, key, mods) do return true // a focused slider moves by its step
		if chart_key(ui, key, mods) do return true // a focused chart walks its points
		if graph_key(ui, key, mods) do return true // …and a focused node graph walks its nodes
		if emoji_key(ui, key, mods) do return true // a focused emoji grid moves its cursor and picks
	}
	if chip_key(ui, key) do return true // Backspace / Delete removes a focused chip
	#partial switch key { // the keys the focus ring itself acts on; the rest go on to the window
	case .Tab:
		if .Ctrl in mods && shortcut_bound(ui, key, mods) do return false // a window's Ctrl+Tab (its tabs) wins; unbound, it still moves focus out
		return focus_next(t, .Shift in mods)
	case .Enter, .Space:
		if menu_unlit_key(ui) do return true // a menu opened with the pointer: only an item the user can see is activated
		if key == .Enter && time_field_enter(ui) do return true // done editing a time in a field's popover
		if key == .Enter && enter_to_default(ui) do return true // a dialog's default button, when the focused control does not use Enter
		if t.focus != NODE_NONE && focusable(t, t.focus) && !is_view(t, t.focus) { // a view had its say: what it declined is the window's
			if click(ui, t.focus) do return true // buttons, checkboxes, toggles, options
		}
	case .Escape:
		if dismiss_escape(ui) do return true // the innermost overlay: a chip's menu before its popover
		if split_escape(ui) do return true // a collapsed split's detail pane goes back
		return panel_escape(ui) // last of all: a bar or an applet hands the keyboard back
	case .Up, .Down:
		return menu_nav(ui, key == .Down)
	case .Page_Up, .Page_Down, .Home, .End:
		if window_nav(key, mods) do return false
		if (key == .Home || key == .End) && menu_end(ui, key == .End) do return true // a menu's first / last item
		return scroll_key(t, key, !shortcut_bound(ui, key, mods), mods) // a bound Page / Home / End beats a scroll the pointer is only over; Shift pans one that scrolls sideways
	case .Menu, .F10:
		if key == .Menu || .Shift in mods do return context_key(ui)
	case .Left, .Right, .Unknown, .F, .G, .H, .Slash, .F3, .B, .I, .U, .E, .K, .Backspace, .Delete, .A, .C, .V, .X, .Z, .Y,
		.D, .J, .L, .M, .N, .O, .P, .Q, .R, .S, .T, .W, .N0, .N1, .N2, .N3, .N4, .N5, .N6, .N7, .N8, .N9, .F1, .F2, .F4, .F5, .F6, .F7, .F8, .F9, .F11, .F12, .Insert, .Minus, .Equal, .Comma, .Period, .Grave, .Bracket_L, .Bracket_R, .Backslash, .Semicolon, .Apostrophe:
		// the widgets above had first refusal; the run loop tries the view's shortcuts next
	}
	return false
}

// panel_escape hands the keyboard back from a bar, a dock or an applet.
//
// A layer surface is not a window: nothing else takes the keyboard away from
// it, so without this every later key would be swallowed. It is the last
// thing Escape tries — a field reverts, a popover closes, a split's detail
// pane goes back first — because it sits at the end of the chain. Focus is
// cleared here and the run loop gives the keyboard back
// (`release_keyboard`), since handing it on is the compositor's job. A
// `.Exclusive` surface is left alone: Escape must not be a way off a lock
// screen.
@(private)
panel_escape :: proc(ui: ^Ui($Msg)) -> bool {
	if ui.surface.kind != .Layer && ui.surface.kind != .Applet do return false
	if !ui.surface.keyboard do return false
	// A surface that binds Escape itself gets it: a full-screen overlay such
	// as a launcher has its own meaning for it, and must not lose the
	// keyboard. The same rule as a bound Ctrl+Tab beating focus traversal. So
	// a panel that binds Escape unconditionally keeps the keyboard; bind it
	// only while it means something.
	if shortcut_bound(ui, .Escape, {}) do return false
	set_focus(&ui.tree, NODE_NONE, false)
	ui.release_keyboard = true
	return true
}

// window_nav: an arrow, Home, End or Page key held with Alt or Super. It is
// the window's (Back, Forward, the enclosing folder), not a view's or a
// control's cursor; text editing keeps its own (Option+arrows by word).
window_nav :: proc "contextless" (key: Key, mods: Mods) -> bool {
	#partial switch key {
	case .Up, .Down, .Left, .Right, .Home, .End, .Page_Up, .Page_Down:
		return mods & {.Alt, .Super} != {}
	}
	return false
}

// is_view: a table, icon view or tree view, which handle their own Enter and
// Space (a key they decline is not a click on them).
@(private)
is_view :: proc(t: ^Tree, n: Node) -> bool {
	return n in t.tables || n in t.icon_views || n in t.tree_views
}

// Focus_At is what a node hearing `focus_track` is told: that the keyboard
// has just arrived on it, or just left it, and whether that move was the
// keyboard's own doing.
//
// `by_key` is true when the move shows a focus ring — Tab, Shift+Tab, an
// arrow walking a group — and false for a click, which is the distinction a
// form filled in from the keyboard needs: Tab reaching a field should open
// its editor, while a click on that field already says so by being a click.
// A `focus` command or `focus = true` reports whatever that ask set the ring
// to, since it stands in for the keyboard.
Focus_At :: struct {
	has:    bool, // the keyboard is on this node now; false: it has just left
	by_key: bool, // the move was the keyboard's (a ring showed), not a click's
}

// focus_track asks to hear when the keyboard arrives on `n` or leaves it, as
// `pointer_track` does for the pointer. A nil handler stops it.
//
// Use it where a field holds a draft the app must act on when the keyboard
// leaves: Tab moves the ring before any widget sees the key. A modifier
// rather than a builder parameter, so it works on any node.
//
//	baldr.focus_track(ui, field, proc(e: baldr.Ev(baldr.Focus_At)) -> Msg {
//		return Field_Focus{at = int(e.tag), has = e.value.has}
//	})
//
// Reported once per move, from `ui_after_events`: the node losing the
// keyboard first, then the node taking it, with the same `by_key`. Nothing
// is reported when the window loses the keyboard (that is `App.on_state`'s),
// nor to a node destroyed while it had it. Give each tracked node its own
// tag, or read `Ev.node`: two sharing a tag read as one node losing the
// keyboard and getting it back.
focus_track :: proc(ui: ^Ui($Msg), n: Node, on_focus: Handler(Msg, Focus_At)) {
	if node_get(&ui.tree, n) == nil do return
	if !handler_live(on_focus) { // not `== nil`: see handler_live
		delete_key(&ui.on_focus, n)
		return
	}
	ui.on_focus[n] = on_focus
}

// focus_tick reports a focus move to the nodes that asked to hear it. Called
// from ui_after_events, so a handler sees a settled focus rather than one
// halfway between the old node and the new.
@(private)
focus_tick :: proc(ui: ^Ui($Msg)) {
	t := &ui.tree
	if t.focus == ui.focus_sent do return
	from, to := ui.focus_sent, t.focus
	ui.focus_sent = to
	if len(ui.on_focus) == 0 do return
	at := Focus_At{by_key = t.focus_visible}
	// The one that lost it hears first: an editor's draft reaches the
	// document before whatever took the keyboard is told to open another.
	if h, has := ui.on_focus[from]; has && node_get(t, from) != nil {
		at.has = false
		handler_send(ui, h, at, from)
	}
	if h, has := ui.on_focus[to]; has {
		at.has = true
		handler_send(ui, h, at, to)
	}
}

// focus_initial puts focus where a scope that just opened wants it: its
// default button (the one Enter means), unless the scope starts with a text
// field, which is what the user came to type into; otherwise its first
// focusable node. A default button shows its ring while the keyboard is in
// use, so the choice is visible; so does the first item of a menu or list
// opened from the keyboard, while one opened with the pointer highlights
// nothing until a key does (menu_nav).
focus_initial :: proc(t: ^Tree, scope: Node) -> bool {
	order := make([dynamic]Node, context.temp_allocator)
	collect_focusable(t, scope, &order)
	if len(order) == 0 do return false
	first := order[0]
	#partial switch node_get(t, first).access.role {
	case .Text_Input, .Search_Box, .Spin_Button:
	case:
		for n in order do if .Default in node_get(t, n).access.states do return set_focus(t, n, t.focus_visible)
	}
	// a menu or list opened from the keyboard shows where it starts; opened with the pointer it highlights
	// nothing until a key does (menu_nav)
	visible := false
	if root := overlay_child_of(t, first); root != NODE_NONE && node_get(t, root).access.role == .Menu do visible = t.focus_visible
	if pages_around(t, first) != NODE_NONE do visible = t.focus_visible // a page reached from the keyboard shows where focus went
	return set_focus(t, first, visible)
}

// default_button_of is the enabled default button inside `scope`, or NONE.
default_button_of :: proc(t: ^Tree, scope: Node) -> Node {
	order := make([dynamic]Node, context.temp_allocator)
	collect_focusable(t, scope, &order)
	for n in order do if .Default in node_get(t, n).access.states do return n
	return NODE_NONE
}

// enter_to_default activates the open dialog's default button when Enter
// reaches the dialog unused: no control focused, a text field that does not
// use Enter, or a checkbox, toggle or radio (Space flips those). A focused
// button, select, tab or menu item keeps its own Enter.
@(private)
enter_to_default :: proc(ui: ^Ui($Msg)) -> bool {
	t := &ui.tree
	if t.modal == NODE_NONE do return false
	def := default_button_of(t, t.modal)
	if def == NODE_NONE do return false
	if f := node_get(t, t.focus); f != nil && t.focus != def {
		#partial switch f.access.role {
		case .Button, .Toggle_Button, .Combo_Box, .Menu_Item, .Tab, .Link: return false
		}
	}
	return click(ui, def)
}

// focus_first moves focus to the first focusable node inside `scope`.
focus_first :: proc(t: ^Tree, scope: Node, visible: bool) -> bool {
	order := make([dynamic]Node, context.temp_allocator)
	collect_focusable(t, scope, &order)
	if len(order) == 0 do return false
	return set_focus(t, order[0], visible)
}

// focus gives the keyboard to the widget built with reconciliation `key`,
// from `update`, so typing just works after a screen opens.
//
//	COMPOSER :: u64(0x_c0m)
//	baldr.text_area(ui, &s.draft, key = COMPOSER)      // in the view
//	return baldr.focus(Msg, COMPOSER)                  // in update
//
// Give that widget a key no other widget uses: every surface is searched and
// the first focusable, enabled, visible node carrying it wins. The ask is
// kept for a few builds, since the command usually causes the field to be
// built, then dropped so an unrelated later screen cannot claim it. A field
// below the fold is scrolled into view. When the view already knows at
// build time, `focus = true` on the widget is simpler.
focus :: proc($Msg: typeid, key: u64) -> Cmd(Msg) {
	return {kind = .Focus, tag = key}
}
