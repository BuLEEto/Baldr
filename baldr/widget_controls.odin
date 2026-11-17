package baldr

// Checkbox, toggle, slider. Each is a Focusable node with a role; checkbox
// and toggle are activated through click() (pointer or Enter/Space) and
// report the flipped value through their Handler; the slider maps pointer x
// to a value while pressed. Toggle and slider paint themselves through
// Custom_Kind; the toggle's knob glides with an anim value.

import "base:runtime"
import "core:math"
import "core:slice"
import "core:strings"

// Slider_State is the slider's model, kept on the tree so paint (which has no
// Msg type) can draw it.
Slider_State :: struct {
	value, min, max, step: f32,
	dragging:              bool,
	size:                  Slider_Size,
	icon:                  Icon, // a Large slider's icon, inside the filled start
	track:                 Slider_Track, // nil = the plain track; else sampled along the track (a colour picker's hue)
	// a slider that scrubs:
	holding:    bool,             // a value was committed: the app's own is not taken until it comes near it, or…
	hold_until: f64,              // …this time (ms) passes: a seek that has not landed yet does not pull the thumb back
	marks:      [dynamic]f32,     // values ticked along the track (slider_options): chapters, bookmarks; owned, sorted
	format:     proc(v: f32) -> string, // the value as it is read ("3:25"): the readout and the accessible value
	value_text: string,           // format(value), kept: the accessible value; owned
	readout:    string,           // format of the value under the pointer (or the thumb, dragged), kept for paint; owned
	readout_x:  f32,              // where it points, in the slider's own x
}

// Slider_Track samples the colour of a slider's track at fraction `f` (0..1).
Slider_Track :: proc(t: ^Tree, n: Node, f: f32) -> Color

CHECKBOX_SIZE :: f32(18)
TOGGLE_W      :: f32(40)
TOGGLE_H      :: f32(22)
SLIDER_H      :: f32(24)
SLIDER_THUMB  :: f32(18)
SLIDER_LARGE_H :: f32(30) // a Large slider's pill, and its knob

// Slider_Size: Regular is the thin track with a small thumb; Large a pill as
// tall as its round knob, the accent filling it, with an icon inside the
// filled start (a quick-settings volume or brightness).
Slider_Size :: enum u8 { Regular, Large }

// checkbox is a labelled on/off control. `on_change` receives the new value.
// `hide_label` keeps `label` as its name without drawing it.
checkbox :: proc(ui: ^Ui($Msg), checked: bool, label: string, on_change: Handler(Msg, bool) = nil,
	disabled := false, hide_label := false, tag: u64 = 0, key: u64 = 0, loc := #caller_location) -> Node {
	n, created := reconcile_child(ui, .Box, key, loc)
	t := &ui.tree
	th := &t.theme
	lk := check_look(th)
	d := node_get(t, n)
	if created {
		d.access.role = .Checkbox
		d.flags += {.Focusable}
		d.layout = {axis = .Row, align = .Center}
		mark_layout_dirty(t, n)
	}
	// Every build, so a theme or density change reaches a checkbox already built.
	lay := d.layout
	lay.gap, lay.padding = lk.gap, lk.padding
	set_layout(t, n, lay)
	if d.style.radius != lk.radius {
		d.style.radius = lk.radius
		mark_paint_dirty(t, n)
	}
	d.tag = tag
	set_name(t, n, label)
	set_checked(t, n, checked)
	set_disabled(t, n, disabled)
	ui.on_bool[n] = on_change

	open_scope(ui, n, loc)
	// indicator: paints itself so the box fills and the tick draws in
	ind, icreated := reconcile_child(ui, .Custom, 0, loc)
	id := node_get(t, ind)
	box_size := [2]f32{lk.indicator_size, lk.indicator_size}
	if ck, ok := id.kind.(Custom_Kind); !ok || icreated || ck.size != box_size {
		id.kind = Custom_Kind{size = box_size, paint = paint_checkbox}
		mark_layout_dirty(t, ind)
	}
	set_style(t, ind, Style{radius = lk.indicator_radius})
	if !hide_label {
		lbl := text(ui, label, role = lk.text.role, size = lk.text.size, color = lk.ink, weight = lk.text.weight, family = look_family(t, lk.text.family), loc = loc)
		set_role(t, lbl, .None)
	}
	close_scope(ui)
	return n
}

// paint_checkbox fills the box with the accent and draws the tick in as the
// Value anim runs 0 → 1 (motion.fast); unchecking plays it backwards.
@(private)
paint_checkbox :: proc(t: ^Tree, n: Node, d: ^Node_Data, l: ^Layer) {
	th := &t.theme
	parent := node_get(t, d.parent)
	if parent == nil do return
	on := .Checked in parent.access.states
	disabled := .Disabled in parent.flags
	k := anim_target(t, n, .Value, 1 if on else 0, th.motion.fast)
	lk := check_look(th)
	bg := mix(lk.fill, lk.selected_fill, k)
	border := lk.border
	border.a *= (1 - k)
	if disabled {
		bg.a *= th.state.disabled_alpha
		border.a *= th.state.disabled_alpha
	}
	bg.a *= t.paint_opacity // the box fades with its dialog, not only the tick
	border.a *= t.paint_opacity
	r := d.abs
	append(&l.cmds, Draw_Rect{rect = r, color = bg, radius = d.style.radius, border_w = lk.border_width, border = border})
	if k > 0.01 {
		c := lk.selected_ink
		c.a *= k * t.paint_opacity
		if disabled do c.a *= th.state.disabled_alpha
		size := r.w * (0.5 + 0.3 * k) // the tick grows in as it appears
		append(&l.cmds, Draw_Icon{pos = {r.x + (r.w - size) / 2, r.y + (r.h - size) / 2}, icon = .Check, size = size, color = c})
	}
}

// toggle is an on/off switch with a gliding knob, its `label` beside it and
// naming it. `hide_label` keeps the name without drawing it (a page header
// whose title already says it).
toggle :: proc(ui: ^Ui($Msg), on: bool, label: string = "", on_change: Handler(Msg, bool) = nil,
	disabled := false, hide_label := false, tag: u64 = 0, key: u64 = 0, loc := #caller_location) -> Node {
	n, created := reconcile_child(ui, .Box, key, loc)
	t := &ui.tree
	th := &t.theme
	lk := toggle_look(th)
	d := node_get(t, n)
	if created {
		d.access.role = .Switch
		d.flags += {.Focusable}
		d.layout = {axis = .Row, align = .Center}
		mark_layout_dirty(t, n)
	}
	// Every build, so a theme or density change reaches a switch already built.
	lay := d.layout
	lay.gap, lay.padding = lk.gap, lk.padding
	set_layout(t, n, lay)
	if d.style.radius != lk.radius {
		d.style.radius = lk.radius
		mark_paint_dirty(t, n)
	}
	d.tag = tag
	set_name(t, n, label if label != "" else "toggle")
	set_checked(t, n, on)
	set_disabled(t, n, disabled)
	ui.on_bool[n] = on_change

	open_scope(ui, n, loc)
	track, tc := reconcile_child(ui, .Custom, 0, loc)
	td := node_get(t, track)
	track_size := [2]f32{lk.track_width, lk.track_height}
	if ck, ok := td.kind.(Custom_Kind); !ok || tc || ck.size != track_size {
		td.kind = Custom_Kind{size = track_size, paint = paint_toggle, overhang = 7} // its knob's shadow
		mark_layout_dirty(t, track)
	}
	// Custom paint reads the parent's Checked state through the tree.
	mark_paint_dirty(t, track)
	if label != "" && !hide_label {
		lbl := text(ui, label, role = lk.text.role, size = lk.text.size, color = lk.ink, weight = lk.text.weight, family = look_family(t, lk.text.family), loc = loc)
		set_role(t, lbl, .None)
	}
	close_scope(ui)
	return n
}

// paint_toggle draws a switch: a pill track that mixes to the accent as it
// comes on, and a round knob sliding across it. Both keep their round ends
// whatever the theme's `radius.full` is: a switch is read by its shape
// before its colour, so it stays a switch in a square-cornered theme.
@(private)
paint_toggle :: proc(t: ^Tree, n: Node, d: ^Node_Data, l: ^Layer) {
	th := &t.theme
	parent := node_get(t, d.parent)
	if parent == nil do return
	on := .Checked in parent.access.states
	k := anim_target(t, n, .Value, 1 if on else 0, th.motion.fast)
	disabled := .Disabled in parent.flags
	op := t.paint_opacity // everything fades with its dialog
	lk := toggle_look(th)
	track_bg := mix(lk.track, lk.selected_track, k)
	if disabled do track_bg.a *= th.state.disabled_alpha
	track_bg.a *= op
	outline := lk.border
	outline.a *= op
	r := d.abs
	append(&l.cmds, Draw_Rect{rect = r, color = track_bg, radius = r.h / 2, border_w = lk.border_width * (1 - k), border = outline})
	knob := lk.thumb_size
	pad := (r.h - knob) / 2
	x := r.x + pad + k * (r.w - knob - 2 * pad)
	knob_c := mix(lk.thumb, lk.selected_thumb, k) // off it reads on the track as on the accent: the knob is what shows the state
	if disabled do knob_c.a *= th.state.disabled_alpha
	knob_c.a *= op
	sh := lk.thumb_shadow
	sc := sh.color
	sc.a *= op
	append(&l.cmds, Draw_Shadow{rect = {x + sh.offset.x, r.y + pad + sh.offset.y, knob, knob}, radius = knob / 2, blur = sh.blur, color = sc})
	append(&l.cmds, Draw_Rect{rect = {x, r.y + pad, knob, knob}, color = knob_c, radius = knob / 2})
}

// icon_toggle is a round on/off button showing `icon`: a quick-settings
// tile's Wi-Fi or Do Not Disturb. On it is the accent with the icon in the
// on-accent colour, off the strong fill with the icon in the content
// colour, easing between them; `size` is its diameter (the theme's
// icon_toggle.size when 0). A click, Enter or Space flips it and `on_change`
// receives the new value. A Toggle_Button named by `label` (the tile's
// title), Pressed while on; the words beside or under it are the app's.
icon_toggle :: proc(ui: ^Ui($Msg), icon: Icon, on: bool, label: string, on_change: Handler(Msg, bool) = nil,
	size: f32 = 0, disabled := false, tag: u64 = 0, key: u64 = 0, loc := #caller_location) -> Node {
	n, created := reconcile_child(ui, .Custom, key, loc)
	t := &ui.tree
	d := node_get(t, n)
	px := size if size > 0 else icon_toggle_look(&t.theme).size
	if created {
		d.access.role = .Toggle_Button
		d.flags += {.Focusable}
	}
	if ck, ok := d.kind.(Custom_Kind); !ok || created || ck.size.x != px {
		d.kind = Custom_Kind{size = {px, px}, paint = paint_icon_toggle}
		d.style.radius = px / 2 // the focus ring goes round it
		mark_layout_dirty(t, n)
	}
	if d.tag != tag do d.tag = tag
	set_name(t, n, label)
	if on != (.Pressed in d.access.states) {
		if on { d.access.states += {.Pressed} } else { d.access.states -= {.Pressed} }
		mark_paint_dirty(t, n)
	}
	set_disabled(t, n, disabled)
	if t.icon_toggles[n] != icon {
		t.icon_toggles[n] = icon
		mark_paint_dirty(t, n)
	}
	ui.on_bool[n] = on_change
	return n
}

ICON_TOGGLE_SIZE :: f32(34)

// paint_icon_toggle draws the circle and its icon, the fill easing between
// off and on over motion.fast, with the hover and press layers of any
// control (none while disabled, which dims it all).
@(private)
paint_icon_toggle :: proc(t: ^Tree, n: Node, d: ^Node_Data, l: ^Layer) {
	th := &t.theme
	c := &th.color
	k := anim_target(t, n, .Value, 1 if .Pressed in d.access.states else 0, th.motion.fast)
	disabled := .Disabled in d.flags
	lk := icon_toggle_look(th)
	bg := mix(lk.fill, lk.pressed_fill, k)
	fg := mix(lk.ink, lk.pressed_ink, k)
	live := !disabled
	pressed := live && .Pressed in d.flags
	hover_k := anim_target(t, n, .Hover, 1 if live && .Hovered in d.flags && !pressed else 0, th.motion.fast)
	press_k := anim_target(t, n, .Press, 1 if pressed else 0, th.motion.fast * 0.6)
	if amount := hover_k * th.state.hover + press_k * th.state.press; amount > 0 {
		// over the accent the content colour mixes in; over the fill, more of the fill
		bg = mix(bg, c.on_surface, amount) if bg.a >= 0.5 else Color{bg.r, bg.g, bg.b, bg.a + amount * (1 - bg.a)}
	}
	op := t.paint_opacity
	bg.a *= op
	fg.a *= op
	if disabled {
		bg.a *= th.state.disabled_alpha
		fg.a *= th.state.disabled_alpha
	}
	r := d.abs
	append(&l.cmds, Draw_Rect{rect = r, color = bg, radius = r.w / 2})
	which := t.icon_toggles[n]
	if which == .None do return
	side := lk.icon_size if lk.icon_size > 0 else math.round(r.w / 2)
	append(&l.cmds, Draw_Icon{pos = {r.x + (r.w - side) / 2, r.y + (r.h - side) / 2}, icon = which, size = side, color = fg})
}

// slider picks a number in [min, max]; `on_change` receives the value while
// dragging (snapped to `step` when > 0). `size = .Large` makes it a pill as
// tall as its round knob, and `icon` shows inside its filled start (pass
// another with the value: a muted speaker at 0). `on_icon` makes a Large
// slider's icon a toggle of its own (a mute): a Toggle_Button named
// `icon_label`, Pressed while `icon_pressed`, a Tab stop before the track.
// A click, Enter or Space on it sends `on_icon`; a press on the track beside
// it still sets the value. Returns the slider itself.
slider :: proc(ui: ^Ui($Msg), value: f32, min: f32 = 0, max: f32 = 1, on_change: Handler(Msg, f32) = nil,
	step: f32 = 0, width: f32 = 0, flex: f32 = 0, size: Slider_Size = .Regular, icon: Icon = .None, label: string = "", disabled := false,
	on_icon: Maybe(Msg) = nil, icon_label: string = "", icon_pressed := false, on_commit: Handler(Msg, f32) = nil,
	focus_on_click := true, tag: u64 = 0, key: u64 = 0, loc := #caller_location) -> Node {
	mute, has_mute := on_icon.?
	if !has_mute || size != .Large || icon == .None do return slider_track(ui, value, min, max, on_change, step, width, flex, size, icon, label, disabled, tag, key, loc, on_commit, focus_on_click)
	t := &ui.tree
	lk := slider_look(&t.theme)
	pill := lk.large.height
	// The icon's toggle and the slider side by side in a wrapper with no role
	// of its own, so assistive technology meets them as siblings (a slider's
	// children are presentational). The toggle comes last, to take presses
	// over the icon and draw its ring over the pill, and first for Tab.
	w, wcreated := reconcile_child(ui, .Custom, key ~ SLIDER_PARTS_KEY, loc)
	if wcreated do node_get(t, w).kind = Custom_Kind{measure = slider_parts_measure}
	set_layout(t, w, Layout_Props{width = width if width > 0 else lk.width, height = pill if pill > target_min(t).y else target_min(t).y, flex = flex}) // the theme's smallest target: the pill is drawn in the middle of it (`max` is the slider's own here)
	open_scope(ui, w, loc)
	n := slider_track(ui, value, min, max, on_change, step, 0, 0, size, icon, label, disabled, tag, 1, loc, on_commit)
	ic, icreated := reconcile_child(ui, .Box, 2, loc)
	id := node_get(t, ic)
	if icreated {
		id.access.role = .Toggle_Button
		id.flags += {.Focusable, .Tab_First}
	}
	id.tag = tag
	set_name(t, ic, icon_label)
	set_disabled(t, ic, disabled)
	if was := .Pressed in id.access.states; was != icon_pressed {
		if icon_pressed { id.access.states += {.Pressed} } else { id.access.states -= {.Pressed} }
		mark_paint_dirty(t, ic)
	}
	ui.clicks[ic] = mute
	is := id.style
	is.radius = pill / 2
	set_style(t, ic, is)
	close_scope(ui)
	return n
}

// SLIDER_PARTS_KEY sets the wrapper of a slider whose icon is a toggle apart
// from a plain slider built at the same place.
@(private)
SLIDER_PARTS_KEY :: u64(0x5117_DE27_0661_E000)

// slider_parts_measure lays out a Large slider whose icon is a toggle: the
// slider across the whole width, the toggle over the icon's circle at its
// start.
@(private)
slider_parts_measure :: proc(t: ^Tree, n: Node, d: ^Node_Data, cc: Constraints) -> [2]f32 {
	h := slider_look(&t.theme).large.height // the pill's height; the wrapper may be taller (the theme's smallest target), with the pill in its middle
	w := cc.max.x if is_bounded(cc.max.x) else d.layout.width
	size := constrain(cc, {max(w, cc.min.x), h})
	track := d.first
	if track == NODE_NONE do return size
	layout_node(t, track, constraints_tight(size))
	td := node_get(t, track)
	td.rect.x, td.rect.y = 0, 0
	if toggle := td.next; toggle != NODE_NONE {
		layout_node(t, toggle, constraints_tight({h, h}))
		od := node_get(t, toggle)
		od.rect.x, od.rect.y = 0, (size.y - h) / 2
	}
	return size
}

// slider_track is the slider itself: a Slider node, painted and driven by
// its state in t.sliders.
@(private)
slider_track :: proc(ui: ^Ui($Msg), value: f32, min: f32, max: f32, on_change: Handler(Msg, f32), step, width, flex: f32,
	size: Slider_Size, icon: Icon, label: string, disabled: bool, tag, key: u64, loc: runtime.Source_Code_Location, on_commit: Handler(Msg, f32) = nil,
	focus_on_click := true) -> Node {
	n, created := reconcile_child(ui, .Custom, key, loc)
	t := &ui.tree
	lk := slider_look(&t.theme)
	d := node_get(t, n)
	focus_on_click_set(t, d, focus_on_click)
	if created {
		d.access.role = .Slider
		d.flags += {.Focusable}
		d.kind = Custom_Kind{size = {width if width > 0 else lk.width, lk.regular.height}, paint = paint_slider, overhang = 12}
		mark_layout_dirty(t, n)
	}
	h := lk.large.height if size == .Large else lk.regular.height
	if ck, ok := d.kind.(Custom_Kind); ok && ck.size.y != h {
		ck.size.y = h
		d.kind = ck
		mark_layout_dirty(t, n)
	}
	if radius := h / 2 if size == .Large else 0; d.style.radius != radius {
		d.style.radius = radius // a Large slider's focus ring follows its pill
		mark_paint_dirty(t, n)
	}
	// As tall as the theme's smallest target where that is more: the height
	// is the slider's own, so layout's minimum cannot pass it, and the track
	// and knob are drawn in the middle.
	set_layout(t, n, Layout_Props{width = width if width > 0 else lk.width, height = h if h > target_min(t).y else target_min(t).y, flex = flex}) // `max` is a parameter here
	d.tag = tag
	set_name(t, n, label if label != "" else "slider")
	set_disabled(t, n, disabled)
	st := &t.sliders[n]
	if st == nil {
		t.sliders[n] = {}
		st = &t.sliders[n]
	}
	// While the thumb is held the drag owns the value, and after a commit the
	// value let go of stands until the app's comes near it or SLIDER_HOLD_MS
	// passes, so a position reported while a seek lands neither pulls the
	// thumb from under the pointer nor flicks it back.
	if st.holding && (abs(value - st.value) <= slider_near(st^) || t.now_ms >= st.hold_until) do st.holding = false
	v := st.value if st.dragging || st.holding else value
	if st.value != v || st.min != min || st.max != max || st.step != step || st.size != size || st.icon != icon {
		st.value, st.min, st.max, st.step, st.size, st.icon = v, min, max, step, size, icon
		slider_value_text(t, n, st)
		mark_paint_dirty(t, n)
	}
	d.access.has_value = true
	d.access.value, d.access.value_min, d.access.value_max = v, min, max
	ui.on_f32[n] = on_change
	if handler_live(on_commit) { ui.slider_commit[n] = on_commit } else { delete_key(&ui.slider_commit, n) }
	return n
}

// slider_options sets a slider's rarer parts, passed every build: `marks`,
// values ticked along its track (an audiobook's chapters, bookmarks), which
// Ctrl + Left / Right step between; and `format`, the value as a reader
// reads it ("3:25" rather than 205) — shown above the thumb while it is
// dragged and above the pointer while it rests on the track, and given to
// assistive technology as the value's text. `format` returns the frame's
// temp memory; what it says is kept.
//
//	s := baldr.slider(ui, pos, 0, dur, on_change = Scrub, on_commit = Seek, label = "Position")
//	baldr.slider_options(ui, s, marks = chapter_starts[:], format = clock_text)
slider_options :: proc(ui: ^Ui($Msg), n: Node, marks: []f32 = nil, format: proc(v: f32) -> string = nil) {
	t := &ui.tree
	st, ok := &t.sliders[n]
	if !ok do return
	slider_marks_set(t, n, st, marks)
	if st.format != format {
		st.format = format
		slider_value_text(t, n, st)
		if d := node_get(t, n); d != nil {
			if ck, is := &d.kind.(Custom_Kind); is do ck.overhang = SLIDER_READOUT_ROOM if format != nil else 12 // the readout above it
		}
		mark_paint_dirty(t, n)
	}
}

// slider_marks_set keeps a slider's marks, sorted, when they change.
@(private)
slider_marks_set :: proc(t: ^Tree, n: Node, st: ^Slider_State, marks: []f32) {
	same := len(st.marks) == len(marks)
	if same do for m, i in marks do if st.marks[i] != m {
		same = false
		break
	}
	if same do return
	if st.marks == nil do st.marks = make([dynamic]f32, t.allocator)
	clear(&st.marks)
	append(&st.marks, ..marks)
	slice.sort(st.marks[:])
	mark_paint_dirty(t, n)
}

// SLIDER_READOUT_ROOM is how far above its track a slider's readout draws.
@(private)
SLIDER_READOUT_ROOM :: f32(34)

// slider_near is how close the app's value must come to a committed one to
// say the seek landed: a step, or half a percent of the range.
@(private)
slider_near :: proc "contextless" (st: Slider_State) -> f32 {
	return max(st.step, (st.max - st.min) / 200)
}

// slider_value_text keeps the formatted value for assistive technology.
@(private)
slider_value_text :: proc(t: ^Tree, n: Node, st: ^Slider_State) {
	text := st.format(st.value) if st.format != nil else ""
	if text != st.value_text {
		delete(st.value_text, t.allocator)
		st.value_text = strings.clone(text, t.allocator)
	}
	if d := node_get(t, n); d != nil do d.access.value_text = st.value_text
}

// slider_readout_set keeps the text shown above the slider: the value at
// `x` (in the slider's own x), or none.
@(private)
slider_readout_set :: proc(t: ^Tree, n: Node, st: ^Slider_State, v: f32, x: f32, show: bool) {
	text := st.format(v) if show && st.format != nil else ""
	if text == st.readout && (!show || x == st.readout_x) do return
	delete(st.readout, t.allocator)
	st.readout = strings.clone(text, t.allocator)
	st.readout_x = x
	mark_paint_dirty(t, n)
}

// slider_hover: the pointer rests on `hover` at `pos`; a slider with a
// format shows the value under it, and the one it left stops.
@(private)
slider_hover :: proc(ui: ^Ui($Msg), pos: [2]f32) {
	t := &ui.tree
	for n, &st in t.sliders {
		if st.format == nil || st.dragging do continue
		over := n == ui.pointer.hover && ui.pointer.inside
		if !over {
			if st.readout != "" do slider_readout_set(t, n, &st, 0, 0, false)
			continue
		}
		d := node_get(t, n)
		v, ok := slider_value_at(t, n, pos.x)
		if d == nil || !ok do continue
		slider_readout_set(t, n, &st, v, clamp(pos.x - d.abs.x, 0, d.abs.w), true)
	}
}

// slider_commit: the value was let go of, or stepped to by a key. An app
// that listens hears it through on_commit (a seek), and the slider holds it
// until the app's value comes near it (or SLIDER_HOLD_MS passes); for one
// that does not, the slider takes the app's value again at once.
@(private)
slider_commit :: proc(ui: ^Ui($Msg), n: Node) {
	t := &ui.tree
	st, ok := &t.sliders[n]
	if !ok do return
	h, has := ui.slider_commit[n]
	if !has do return // no seek to wait for: the app's value is taken as it comes
	st.holding = true
	st.hold_until = t.now_ms + SLIDER_HOLD_MS
	handler_send(ui, h, st.value, n)
}

// SLIDER_HOLD_MS is the longest a committed value stands against the app's.
SLIDER_HOLD_MS :: 1000.0

@(private)
slider_state_free :: proc(t: ^Tree, st: ^Slider_State) {
	delete(st.marks)
	delete(st.value_text, t.allocator)
	delete(st.readout, t.allocator)
	st.marks, st.value_text, st.readout = nil, "", ""
}

@(private)
paint_slider :: proc(t: ^Tree, n: Node, d: ^Node_Data, l: ^Layer) {
	th := &t.theme
	st, ok := t.sliders[n]
	if !ok do return
	lk := slider_look(th)
	if st.size == .Large {
		paint_slider_large(t, n, d, l, st, lk)
		return
	}
	rl := lk.regular
	ts := rl.thumb_size
	r := d.abs
	frac := slider_fraction(st)
	track_h := rl.track_height
	ty := r.y + (r.h - track_h) / 2
	inner_w := r.w - ts
	fill_w := inner_w * frac
	disabled := .Disabled in d.flags
	op := t.paint_opacity // everything fades with its dialog
	track_c := rl.track
	fill_c := rl.fill
	thumb_c := rl.thumb
	if disabled {
		track_c.a *= th.state.disabled_alpha
		fill_c.a *= th.state.disabled_alpha
		thumb_c.a *= th.state.disabled_alpha
	}
	track_c.a *= op
	fill_c.a *= op
	if st.track != nil {
		// a sampled track (a colour picker): segments in the colours the slider selects
		track_h = 10
		ty = r.y + (r.h - track_h) / 2
		segs := 32
		x0 := r.x + ts / 2
		seg_w := inner_w / f32(segs)
		append(&l.cmds, Draw_Clip_Push{{x0, ty, inner_w, track_h}})
		for i in 0 ..< segs {
			c := st.track(t, n, (f32(i) + 0.5) / f32(segs))
			c.a *= t.paint_opacity
			if disabled do c.a *= th.state.disabled_alpha
			append(&l.cmds, Draw_Rect{rect = {x0 + f32(i) * seg_w, ty, seg_w + 0.5, track_h}, color = c})
		}
		append(&l.cmds, Draw_Clip_Pop{})
		edge := th.color.outline_variant
		edge.a *= op
		append(&l.cmds, Draw_Rect{rect = {x0, ty, inner_w, track_h}, radius = track_h / 2, border_w = 1, border = edge})
		thumb_c = st.track(t, n, frac)
		if disabled do thumb_c.a *= th.state.disabled_alpha
	} else {
		append(&l.cmds, Draw_Rect{rect = {r.x + ts / 2, ty, inner_w, track_h}, color = track_c, radius = track_h / 2})
		append(&l.cmds, Draw_Rect{rect = {r.x + ts / 2, ty, fill_w, track_h}, color = fill_c, radius = track_h / 2})
	}
	slider_paint_marks(t, l, st, r.x + ts / 2, inner_w, r.y + r.h / 2, track_h + 6, frac, disabled, op)
	tx := r.x + fill_w
	ty2 := r.y + (r.h - ts) / 2
	thumb_c.a *= op
	if !disabled {
		sh := rl.thumb_shadow
		sc := sh.color
		sc.a *= op
		append(&l.cmds, Draw_Shadow{rect = {tx + sh.offset.x, ty2 + sh.offset.y, ts, ts}, radius = ts / 2, blur = sh.blur, color = sc})
	}
	rim := rl.thumb_border if st.track == nil else th.color.surface
	rim.a *= op
	append(&l.cmds, Draw_Rect{rect = {tx, ty2, ts, ts}, color = thumb_c, radius = ts / 2, border_w = rl.thumb_border_width, border = rim})
	// Hover / press / focus feedback is a halo around the thumb, not a box
	// over the whole track: eased like the state layers on other controls.
	halo := anim_target(t, n, .Hover, 1 if (.Hovered in d.flags || .Focused in d.flags) && !st.dragging && !disabled else 0, th.motion.fast)
	press := anim_target(t, n, .Press, 1 if st.dragging else 0, th.motion.fast * 0.6)
	if a := halo * 0.12 + press * 0.25; a > 0.005 {
		ring := rl.fill
		ring.a = a * op
		append(&l.cmds, Draw_Rect{rect = {tx - 6, ty2 - 6, ts + 12, ts + 12}, color = ring, radius = ts / 2 + 6})
	}
	slider_paint_readout(t, l, lk, st, r, op)
}

// slider_paint_marks ticks each mark across the track, centred at `cy`:
// the colour that reads on the fill where the fill has reached it, the
// muted ink where it has not.
@(private)
slider_paint_marks :: proc(t: ^Tree, l: ^Layer, st: Slider_State, x0, w, cy, h: f32, frac: f32, disabled: bool, op: f32) {
	if len(st.marks) == 0 || st.max <= st.min do return
	th := &t.theme
	for m in st.marks {
		f := clamp((m - st.min) / (st.max - st.min), 0, 1)
		c := th.color.on_primary if f <= frac else th.color.on_surface_muted
		c.a *= op * (th.state.disabled_alpha if disabled else 1)
		append(&l.cmds, Draw_Rect{rect = {x0 + w * f - 1, cy - h / 2, 2, h}, color = c, radius = 1})
	}
}

// slider_paint_readout draws the formatted value above the slider where the
// pointer rests or the thumb is dragged: a small bubble, kept inside the
// slider's width.
@(private)
slider_paint_readout :: proc(t: ^Tree, l: ^Layer, lk: Slider_Look, st: Slider_State, r: Rect, op: f32) {
	text := st.readout
	x := r.x + st.readout_x
	if st.dragging && st.format != nil {
		text = st.value_text // the thumb's own value, where the thumb is
		thumb := slider_thumb(lk, st)
		x = r.x + thumb / 2 + (r.w - thumb) * slider_fraction(st)
	}
	if text == "" do return
	ro := lk.readout
	size := ro.text.size
	family := look_family(t, ro.text.family)
	w := text_measure(t, text, size, 0, ro.text.weight, family = family).x + 12
	bx := clamp(x - w / 2, r.x, r.x + r.w - w)
	by := r.y - 26
	bg, ink, edge := ro.fill, ro.ink, ro.border
	bg.a *= op
	ink.a *= op
	edge.a *= op
	append(&l.cmds, Draw_Rect{rect = {bx, by, w, 22}, color = bg, radius = ro.radius, border_w = 1, border = edge})
	append(&l.cmds, Draw_Text{pos = {bx + 6, by + 4}, str = text, size = size, color = ink, weight = ro.text.weight, family = family})
}

// paint_slider_large draws a Large slider: a pill track in the strong fill,
// the accent filling it up to and under a round knob, and the icon inside
// the start in the colour that reads on what lies under it (the accent's,
// the track's, or the knob's when the knob is over it). The pill keeps its
// height, centred in whatever height layout gave the slider.
//
// It stays a pill whatever the theme's `radius.full` is, as a switch does:
// the knob is a circle as tall as the track, so squaring the track alone
// would leave corners poking out around it.
@(private)
paint_slider_large :: proc(t: ^Tree, n: Node, d: ^Node_Data, l: ^Layer, st: Slider_State, lk: Slider_Look) {
	th := &t.theme
	lg := lk.large
	h := min(lg.height, d.abs.h)
	r := Rect{d.abs.x, d.abs.y + (d.abs.h - h) / 2, d.abs.w, h}
	kx := r.x + (r.w - h) * slider_fraction(st) // the knob's left edge
	disabled := .Disabled in d.flags
	op := t.paint_opacity
	faded :: proc(col: Color, op: f32, disabled: bool, dim: f32) -> Color {
		out := col
		out.a *= op
		if disabled do out.a *= dim
		return out
	}
	dim := th.state.disabled_alpha
	append(&l.cmds, Draw_Rect{rect = r, color = faded(lg.track, op, disabled, dim), radius = h / 2})
	append(&l.cmds, Draw_Rect{rect = {r.x, r.y, kx + h - r.x, h}, color = faded(lg.fill, op, disabled, dim), radius = h / 2})
	if !disabled {
		sh := lg.thumb_shadow
		sc := sh.color
		sc.a *= op
		append(&l.cmds, Draw_Shadow{rect = {kx + sh.offset.x, r.y + sh.offset.y, h, h}, radius = h / 2, blur = sh.blur, color = sc})
	}
	append(&l.cmds, Draw_Rect{rect = {kx, r.y, h, h}, color = faded(lg.thumb, op, disabled, dim), radius = h / 2})
	halo := anim_target(t, n, .Hover, 1 if (.Hovered in d.flags || .Focused in d.flags) && !st.dragging && !disabled else 0, th.motion.fast)
	press := anim_target(t, n, .Press, 1 if st.dragging else 0, th.motion.fast * 0.6)
	if a := halo * 0.12 + press * 0.25; a > 0.005 {
		ring := lg.fill
		ring.a = a * op
		append(&l.cmds, Draw_Rect{rect = {kx - 5, r.y - 5, h + 10, h + 10}, color = ring, radius = h / 2 + 5})
	}
	slider_paint_marks(t, l, st, r.x + h / 2, r.w - h, r.y + h / 2, h * 0.4, slider_fraction(st), disabled, op)
	slider_paint_readout(t, l, lk, st, d.abs, op)
	if st.icon == .None do return
	side := lg.icon_size if h >= lg.height else math.round(h * 0.54) // squeezed, the icon shrinks with the pill
	ix, iy := r.x + math.round((h - side) / 2) + 2, r.y + math.round((h - side) / 2)
	mid := ix + side / 2
	fg := lg.fill_ink // on the accent
	switch {
	case mid >= kx && mid <= kx + h: fg = lg.thumb_ink // under the knob
	case mid > kx + h:               fg = lg.track_ink // on the track, past the fill
	}
	append(&l.cmds, Draw_Icon{pos = {ix, iy}, icon = st.icon, size = side, color = faded(fg, op, disabled, dim)})
}

// slider_thumb is the size of a slider's thumb: its knob, which on a Large
// slider is as tall as the pill.
@(private)
slider_thumb :: proc "contextless" (lk: Slider_Look, st: Slider_State) -> f32 {
	return lk.large.height if st.size == .Large else lk.regular.thumb_size
}

@(private)
slider_fraction :: proc "contextless" (st: Slider_State) -> f32 {
	if st.max <= st.min do return 0
	return clamp((st.value - st.min) / (st.max - st.min), 0, 1)
}

// slider_value_at maps a pointer x to the slider's value (snapped to step).
slider_value_at :: proc(t: ^Tree, n: Node, x: f32) -> (f32, bool) {
	d := node_get(t, n)
	st, ok := t.sliders[n]
	if d == nil || !ok do return 0, false
	thumb := slider_thumb(slider_look(&t.theme), st) // the same thumb paint draws, so a press lands where it shows
	inner_w := max(d.abs.w - thumb, 1)
	frac := clamp((x - d.abs.x - thumb / 2) / inner_w, 0, 1)
	v := st.min + frac * (st.max - st.min)
	if st.step > 0 do v = st.min + math.round((v - st.min) / st.step) * st.step
	return clamp(v, st.min, st.max), true
}

// slider_pointer handles a press or drag at `pos`: updates the model, paints,
// and sends on_change when the value changed. Returns true if consumed.
slider_pointer :: proc(ui: ^Ui($Msg), n: Node, pos: [2]f32) -> bool {
	t := &ui.tree
	d := node_get(t, n)
	if d == nil || .Disabled in d.flags do return false
	v, ok := slider_value_at(t, n, pos.x)
	if !ok do return false
	st := &t.sliders[n]
	if !st.dragging && st.readout != "" do slider_readout_set(t, n, st, 0, 0, false) // held: the thumb's own value shows instead
	st.dragging = true
	slider_set(ui, n, v)
	return true
}

// slider_set adopts a value: the thumb moves, on_change carries it when
// it changed, and a colour picker owning the slider recomputes.
@(private)
slider_set :: proc(ui: ^Ui($Msg), n: Node, v: f32) -> (changed: bool) {
	t := &ui.tree
	d := node_get(t, n)
	st := &t.sliders[n]
	if d == nil || st == nil do return false
	changed = st.value != v
	st.value = v
	d.access.value = v
	if changed do slider_value_text(t, n, st)
	mark_paint_dirty(t, n)
	if changed {
		if h, has := ui.on_f32[n]; has do handler_send(ui, h, v, n)
		if pk, owned := t.picker_of[n]; owned do picker_slider_changed(ui, pk)
	}
	return
}

// slider_key: Left / Down and Right / Up move by `step` (a hundredth of
// the range when there is none), Page Up / Down by a tenth, Home / End to
// the ends.
slider_key :: proc(ui: ^Ui($Msg), key: Key, mods: Mods) -> bool {
	t := &ui.tree
	n := t.focus
	st, ok := &t.sliders[n]
	if !ok do return false
	if d := node_get(t, n); d == nil || .Disabled in d.flags do return false
	span := st.max - st.min
	step := st.step if st.step > 0 else span / 100
	if .Shift in mods do step *= 10
	v := st.value
	if .Ctrl in mods && len(st.marks) > 0 { // Ctrl: from mark to mark (a chapter back, a chapter on)
		#partial switch key {
		case .Left, .Down:
			to, found := st.min, false
			for m in st.marks do if m < v - slider_near(st^) / 2 { to, found = m, true }
			v = to if found else st.min
		case .Right, .Up:
			to := st.max
			for i := len(st.marks) - 1; i >= 0; i -= 1 do if st.marks[i] > v + slider_near(st^) / 2 do to = st.marks[i]
			v = to
		case: return false
		}
		slider_set(ui, n, clamp(v, st.min, st.max))
		slider_commit(ui, n)
		return true
	}
	#partial switch key {
	case .Left, .Down:       v -= step
	case .Right, .Up:        v += step
	case .Page_Down:         v -= span / 10
	case .Page_Up:           v += span / 10
	case .Home:              v = st.min
	case .End:               v = st.max
	case: return false
	}
	v = clamp(v, st.min, st.max)
	if st.step > 0 do v = st.min + f32(int((v - st.min) / st.step + 0.5)) * st.step
	slider_set(ui, n, clamp(v, st.min, st.max))
	slider_commit(ui, n) // a key's step is its own commit: there is no letting go of it
	return true
}

@(private)
set_checked :: proc(t: ^Tree, n: Node, checked: bool) {
	d := node_get(t, n)
	if d == nil do return
	was := .Checked in d.access.states
	if was == checked do return
	if checked { d.access.states += {.Checked} } else { d.access.states -= {.Checked} }
	mark_paint_dirty(t, n)
}

@(private)
set_disabled :: proc(t: ^Tree, n: Node, disabled: bool) {
	d := node_get(t, n)
	if d == nil || (.Disabled in d.flags) == disabled do return
	if disabled {
		d.flags += {.Disabled}
		d.access.states += {.Disabled}
	} else {
		d.flags -= {.Disabled}
		d.access.states -= {.Disabled}
	}
	mark_paint_dirty(t, n)
}
