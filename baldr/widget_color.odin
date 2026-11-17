package baldr

// color_picker: a swatch, a hex field and three sliders — Hue, Chroma and
// Lightness in OKLCH, the space the themes are built in, so every step
// along a slider is a perceptually even one and the tracks show exactly
// the colours they select. The colour is the app's state (on_change
// carries the new one); the sliders and the hex field are keyboard
// operable like any slider or field (Enter commits the hex, Escape puts
// it back, leaving the field commits). Accessibility: a Group named
// `label` of Sliders "Hue", "Chroma", "Lightness" and a field "Hex".
//
//	baldr.color_picker(ui, s.accent, proc(e: baldr.Ev(baldr.Color)) -> Msg { return Set_Accent{e.value} })

import "base:runtime"
import "core:fmt"
import "core:strconv"
import "core:strings"

PICKER_CHROMA_MAX :: f32(0.37)

Picker_State :: struct {
	L, C, h:  f32,
	hex:      Text,   // the field's buffer, owned here
	last:     Color,  // the colour the app passed last build
	field, hue, chroma, light, swatch: Node,
}

@(private)
picker_state_free :: proc(t: ^Tree, ps: ^Picker_State) {
	text_destroy(&ps.hex)
	free(ps, t.allocator)
}

color_picker :: proc(ui: ^Ui($Msg), color: Color, on_change: Handler(Msg, Color) = nil, label: string = "Colour",
	width: f32 = 280, key: u64 = 0, loc := #caller_location) -> Node {
	t := &ui.tree
	th := &t.theme
	n, created := reconcile_child(ui, .Box, key, loc)
	d := node_get(t, n)
	if created {
		d.access.role = .Group
		ps := new(Picker_State, t.allocator)
		ps.hex = text_make("", t.allocator)
		ps.last = {-1, -1, -1, -1}
		t.pickers[n] = ps
	}
	set_name(t, n, label)
	set_layout(t, n, Layout_Props{axis = .Column, align = .Stretch, gap = th.space[.sm], width = width})
	ps := t.pickers[n]
	if color != ps.last { // the app changed it: the sliders and the field follow
		L, C, h := oklch_of(color)
		ps.L, ps.C = L, C
		if C > 0.002 || ps.last == {-1, -1, -1, -1} do ps.h = h
		ps.last = color
		if !(ps.field != NODE_NONE && t.focus == ps.field) do text_set(&ps.hex, color_hex(color))
	}
	ui.on_color[n] = on_change
	cur := oklch(ps.L, ps.C, ps.h)
	open_scope(ui, n, loc)
	row(ui, align = .Center, gap = .md, key = 1, loc = loc)
	ps.swatch = box(ui, width = 40, height = 40, bg = cur, radius = th.radius.md, loc = loc)
	sd := node_get(t, ps.swatch)
	sst := sd.style
	sst.border_w = 1
	sst.border = th.color.outline_variant
	set_style(t, ps.swatch, sst)
	sd.access.role = .Image
	set_name(t, ps.swatch, color_hex(cur))
	ps.field = text_input(ui, &ps.hex, label = "Hex", width = 110, loc = loc)
	t.picker_of[ps.field] = n
	end(ui)
	ps.hue = picker_slider(ui, n, "Hue", ps.h, 0, 360, picker_track_hue, 2, loc)
	ps.chroma = picker_slider(ui, n, "Chroma", ps.C, 0, PICKER_CHROMA_MAX, picker_track_chroma, 3, loc)
	ps.light = picker_slider(ui, n, "Lightness", ps.L, 0, 1, picker_track_light, 4, loc)
	close_scope(ui)
	return n
}

@(private)
picker_slider :: proc(ui: ^Ui($Msg), picker: Node, name: string, value, min, max: f32, track: Slider_Track, key: u64, loc: runtime.Source_Code_Location) -> Node {
	t := &ui.tree
	row(ui, align = .Center, gap = .md, key = key, loc = loc)
	lbl := text(ui, name, role = .Caption, muted = true, nowrap = true, loc = loc)
	set_layout(t, lbl, Layout_Props{width = 64})
	set_role(t, lbl, .None)
	s := slider(ui, value, min = min, max = max, flex = 1, label = name, loc = loc)
	t.picker_of[s] = picker
	if st := &t.sliders[s]; st != nil do st.track = track
	end(ui)
	return s
}

// picker_slider_changed recomputes the colour from the sliders and sends
// it. The sliders stay where the user put them: the colour they make is
// gamut-mapped (a chroma the display cannot show is pulled in), but the
// thumbs are not pulled back — that would keep the chroma slider from
// ever reaching its ends and make the hue jump when chroma hits zero.
@(private)
picker_slider_changed :: proc(ui: ^Ui($Msg), picker: Node) {
	t := &ui.tree
	ps, ok := t.pickers[picker]
	if !ok do return
	if st, has := t.sliders[ps.hue]; has do ps.h = st.value
	if st, has := t.sliders[ps.chroma]; has do ps.C = st.value
	if st, has := t.sliders[ps.light]; has do ps.L = st.value
	picker_commit(ui, picker, oklch(ps.L, ps.C, ps.h), from_sliders = true)
}

// picker_commit adopts a colour: swatch, field and sliders show it, and
// on_change carries it. From the sliders the L / C / h are theirs; from a
// hex or the app the sliders follow the colour (keeping the hue when the
// colour is grey, where hue means nothing).
@(private)
picker_commit :: proc(ui: ^Ui($Msg), picker: Node, c: Color, from_sliders := false) {
	t := &ui.tree
	ps, ok := t.pickers[picker]
	if !ok do return
	if !from_sliders {
		L, C, h := oklch_of(c)
		ps.L, ps.C = L, C
		if C > 0.002 do ps.h = h
	}
	for pair in ([3]struct{n: Node, v: f32}{{ps.hue, ps.h}, {ps.chroma, ps.C}, {ps.light, ps.L}}) {
		if st := &t.sliders[pair.n]; st != nil && st.value != pair.v {
			st.value = pair.v
			if sd := node_get(t, pair.n); sd != nil do sd.access.value = pair.v
			mark_paint_dirty(t, pair.n)
		}
	}
	if !(t.focus == ps.field) do text_set(&ps.hex, color_hex(c))
	if fd := node_get(t, ps.field); fd != nil {
		if s, has := &t.inputs[ps.field]; has do input_refresh(t, ps.field, fd, s)
		mark_paint_dirty(t, ps.field)
	}
	if sd := node_get(t, ps.swatch); sd != nil {
		sd.style.bg = c
		set_name(t, ps.swatch, color_hex(c))
		mark_paint_dirty(t, ps.swatch)
	}
	if c == ps.last do return
	ps.last = c
	if h, has := ui.on_color[picker]; has do handler_send(ui, h, c, picker)
}

// picker_key: Enter commits the hex field, Escape puts the colour back.
picker_key :: proc(ui: ^Ui($Msg), key: Key, mods: Mods) -> bool {
	t := &ui.tree
	picker, ok := t.picker_of[t.focus]
	if !ok do return false
	ps := t.pickers[picker]
	if t.focus != ps.field do return false
	ui.picker_focused = t.focus
	#partial switch key {
	case .Enter:
		if c, parsed := color_parse_hex(string(ps.hex.buf[:])); parsed {
			picker_commit(ui, picker, c)
		} else {
			text_set(&ps.hex, color_hex(ps.last))
			if fd := node_get(t, ps.field); fd != nil {
				if s, has := &t.inputs[ps.field]; has do input_refresh(t, ps.field, fd, s)
				mark_paint_dirty(t, ps.field)
			}
		}
		text_input_select_all(t, ps.field) // the commit shows as a selection, as in every value field
		return true
	case .Escape:
		if string(ps.hex.buf[:]) == color_hex(ps.last) do return false // nothing to revert: let Escape close the popover
		text_set(&ps.hex, color_hex(ps.last))
		if fd := node_get(t, ps.field); fd != nil {
			if s, has := &t.inputs[ps.field]; has do input_refresh(t, ps.field, fd, s)
			mark_paint_dirty(t, ps.field)
		}
		return true
	}
	return false
}

// picker_tick commits the hex field when focus leaves it.
@(private)
picker_tick :: proc(ui: ^Ui($Msg)) {
	t := &ui.tree
	if pk, is_field := t.picker_of[t.focus]; is_field && t.pickers[pk].field == t.focus {
		ui.picker_focused = t.focus
		return
	}
	if ui.picker_focused == NODE_NONE do return
	left := ui.picker_focused
	ui.picker_focused = NODE_NONE
	picker, ok := t.picker_of[left]
	if !ok do return
	ps := t.pickers[picker]
	if c, parsed := color_parse_hex(string(ps.hex.buf[:])); parsed {
		picker_commit(ui, picker, c)
	} else {
		text_set(&ps.hex, color_hex(ps.last))
		if fd := node_get(t, ps.field); fd != nil {
			if s, has := &t.inputs[ps.field]; has do input_refresh(t, ps.field, fd, s)
			mark_paint_dirty(t, ps.field)
		}
	}
}

// track samplers: what the colour becomes along each slider
@(private)
picker_track_hue :: proc(t: ^Tree, n: Node, f: f32) -> Color {
	ps := t.pickers[t.picker_of[n]]
	return oklch(ps.L, max(ps.C, 0.08), f * 360)
}
@(private)
picker_track_chroma :: proc(t: ^Tree, n: Node, f: f32) -> Color {
	ps := t.pickers[t.picker_of[n]]
	return oklch(ps.L, f * PICKER_CHROMA_MAX, ps.h)
}
@(private)
picker_track_light :: proc(t: ^Tree, n: Node, f: f32) -> Color {
	ps := t.pickers[t.picker_of[n]]
	return oklch(f, ps.C, ps.h)
}

// color_hex writes a Color as "#rrggbb" (sRGB), in the frame's temp memory:
// copy it into anything you keep.
color_hex :: proc(c: Color) -> string {
	to8 :: proc "contextless" (v: f32) -> int { return clamp(int(linear_to_srgb(clamp(v, 0, 1)) * 255 + 0.5), 0, 255) }
	return fmt.tprintf("#%02x%02x%02x", to8(c.r), to8(c.g), to8(c.b))
}

// color_parse_hex reads "#rrggbb", "rrggbb" or "#rgb".
color_parse_hex :: proc(s: string) -> (c: Color, ok: bool) {
	h := strings.trim_space(s)
	if strings.has_prefix(h, "#") do h = h[1:]
	if len(h) == 3 {
		buf: [6]u8
		for i in 0 ..< 3 { buf[2 * i], buf[2 * i + 1] = h[i], h[i] }
		h = string(buf[:])
		v, vok := strconv.parse_u64_of_base(h, 16)
		if !vok do return {}, false
		return rgb(u32(v)), true
	}
	if len(h) != 6 do return {}, false
	v, vok := strconv.parse_u64_of_base(h, 16)
	if !vok do return {}, false
	return rgb(u32(v)), true
}

// color_field is the drop-down form: a swatch and the hex, opening a
// color_picker in a popover on click, Enter or Space; Escape or a press
// elsewhere closes it. Accessibility: Combo_Box named `label` described
// by the hex, with a popup, Expanded while open.
//
//	baldr.color_field(ui, s.accent, proc(e: baldr.Ev(baldr.Color)) -> Msg { return Set_Accent{e.value} }, label = "Accent")
color_field :: proc(ui: ^Ui($Msg), color: Color, on_change: Handler(Msg, Color) = nil, label: string = "Colour",
	width: f32 = 150, disabled := false, tag: u64 = 0, key: u64 = 0, loc := #caller_location) -> Node {
	t := &ui.tree
	th := &t.theme
	lk := field_look(th)
	n, created := reconcile_child(ui, .Box, key, loc)
	d := node_get(t, n)
	if created {
		d.access.role = .Combo_Box
		d.flags += {.Focusable, .Clips}
		ui.open[n] = false
	}
	d.tag = tag
	set_name(t, n, label)
	set_disabled(t, n, disabled)
	hex := color_hex(color)
	if d.access.describe != hex do set_describe(t, n, hex)
	is_open := ui.open[n]
	popup_states(d, is_open) // it opens a popup: Has_Popup, Expanded while open
	// The swatch leads, so the start is the inset rather than a drop-down's padding.
	pad := lk.dropdown_padding
	set_layout(t, n, Layout_Props{axis = .Row, align = .Center, justify = .Space_Between, width = width, min_h = lk.min_height,
		padding = {pad[0], pad[1], pad[2], lk.inset}, gap = lk.gap})
	st := d.style
	st.bg = lk.fill
	st.radius = lk.radius
	st.border_w = lk.focus_border_width if is_open else lk.border_width
	st.border = lk.focus_border if is_open else lk.border
	set_style(t, n, st)
	open_scope(ui, n, loc)
	sw := box(ui, width = lk.swatch.size, height = lk.swatch.size, bg = color, radius = lk.swatch.radius, loc = loc)
	sd := node_get(t, sw)
	sst := sd.style
	sst.border_w = 1
	sst.border = th.color.outline_variant
	set_style(t, sw, sst)
	vsize, vfam := field_value_size(t, lk), field_value_family(t, lk)
	lbl := text(ui, hex, size = vsize, color = lk.ink, nowrap = true, weight = lk.value_weight, family = vfam, loc = loc)
	set_role(t, lbl, .None)
	set_layout(t, lbl, Layout_Props{flex = 1})
	baldr_icon(ui, .Chevron_Down, lk.icon_size, lk.icon, loc)
	close_scope(ui)
	if is_open && !disabled {
		k := (u64(n) * 0x9E37_79B9_7F4A_7C15) | 1
		pop, pcreated := overlay_begin(ui, k, loc)
		popover_style(ui, pop, pcreated, n, .Below, 0, true)
		set_rule(ui, pop, Dismiss_Rule(Msg){owner = n, anchor = n, inside = pop, restore = n})
		color_picker(ui, color, on_change, label = label, loc = loc)
		if pcreated do ui.pending_focus = pop
		end(ui)
	}
	return n
}
