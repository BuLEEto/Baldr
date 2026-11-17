package baldr

// number_input: a field for a number with − / + buttons. Up / Down step
// it (Shift: ten steps), Enter commits what was typed, Escape puts the
// value back, and leaving the field commits too; the value is clamped to
// `min` / `max` and shown with as many decimals as `step` has. The value is
// the app's state; on_change carries the new one. Accessibility: the field
// is a Spin_Button named `label` with value / min / max; the buttons are
// "Decrease <label>" and "Increase <label>".
//
//	baldr.number_input(ui, s.count, proc(e: baldr.Ev(f32)) -> Msg { return Set_Count{e.value} }, min = 0, max = 100, label = "Count")

import "base:builtin"
import "base:runtime"
import "core:fmt"
import "core:strconv"
import "core:strings"

NUMBER_BUTTON :: f32(30)

Spin_State :: struct {
	text:     Text, // the field's buffer, owned here
	value:    f32,  // last value shown or committed
	min, max: f32,
	step:     f32,
	decimals: int,
	field:    Node,
	label:    string, // owned
}

// Spin_Step is a press on one of a number input's stepper buttons: which
// input, and which way.
Spin_Step :: struct {
	outer: Node,
	dir:   int,
}

@(private)
spin_state_free :: proc(t: ^Tree, sp: ^Spin_State) {
	text_destroy(&sp.text)
	if len(sp.label) > 0 do delete(sp.label, t.allocator)
	free(sp, t.allocator)
}

number_input :: proc(ui: ^Ui($Msg), value: f32, on_change: Handler(Msg, f32) = nil, min: f32 = -3.4e38, max: f32 = 3.4e38,
	step: f32 = 1, label: string = "", width: f32 = 150, disabled := false, tag: u64 = 0, key: u64 = 0, loc := #caller_location) -> Node {
	t := &ui.tree
	lk := field_look(&t.theme)
	n, created := reconcile_child(ui, .Box, key, loc)
	d := node_get(t, n)
	if created {
		d.access.role = .None
		sp := new(Spin_State, t.allocator)
		sp.text = text_make("", t.allocator)
		sp.value = value
		t.spins[n] = sp
	}
	d.tag = tag
	set_layout(t, n, Layout_Props{axis = .Row, align = .Center, gap = lk.stepper.gap, width = width})
	sp := t.spins[n]
	sp.min, sp.max, sp.step = min, max, builtin.max(step, 0)
	sp.decimals = step_decimals(step)
	if sp.label != label {
		if len(sp.label) > 0 do delete(sp.label, t.allocator)
		sp.label = strings.clone(label, t.allocator)
	}
	editing := sp.field != NODE_NONE && t.focus == sp.field
	if !editing && (created || sp.value != value || len(sp.text.buf) == 0) {
		sp.value = clamp(value, min, max)
		text_set(&sp.text, number_format(t, sp.value, sp.decimals))
	}
	ui.on_number[n] = on_change
	open_scope(ui, n, loc)
	field := text_input(ui, &sp.text, label = label, flex = 1, disabled = disabled, tag = tag, loc = loc)
	fd := node_get(t, field)
	fd.access.role = .Spin_Button
	fd.access.has_value = true
	fd.access.value, fd.access.value_min, fd.access.value_max = sp.value, min, max
	sp.field = field
	t.spin_of[field] = n
	spin_button(ui, &lk, n, -1, .Minus, spin_button_name("Decrease", label), disabled || sp.value <= min, 0x5B01, loc)
	spin_button(ui, &lk, n, +1, .Plus, spin_button_name("Increase", label), disabled || sp.value >= max, 0x5B02, loc)
	close_scope(ui)
	return n
}

@(private)
spin_button_name :: proc(verb, label: string) -> string {
	return fmt.tprintf("%s %s", verb, label) if label != "" else verb
}

@(private)
spin_button :: proc(ui: ^Ui($Msg), lk: ^Field_Look, outer: Node, dir: int, ic: Icon, name: string, disabled: bool, key: u64, loc: runtime.Source_Code_Location) {
	t := &ui.tree
	b, created := reconcile_child(ui, .Box, key, loc)
	d := node_get(t, b)
	if created {
		d.access.role = .Button
		d.flags += {.Focusable}
	}
	set_name(t, b, name)
	set_disabled(t, b, disabled)
	ui.spin_step[b] = {outer = outer, dir = dir}
	set_layout(t, b, Layout_Props{axis = .Row, align = .Center, justify = .Center, width = lk.stepper.size, height = lk.stepper.size})
	st := d.style
	st.radius = lk.stepper.radius
	st.bg = lk.stepper.fill
	set_style(t, b, st)
	open_scope(ui, b, loc)
	baldr_icon(ui, ic, lk.icon_size, lk.stepper.ink, loc)
	close_scope(ui)
}

// step_decimals: how many decimals `step` needs (0.25 → 2), at most 6.
step_decimals :: proc "contextless" (step: f32) -> int {
	s := step
	for d in 0 ..< 6 {
		if abs(s - f32(int(s + 0.5 if s >= 0 else s - 0.5))) < 1e-4 do return d
		s *= 10
	}
	return 6
}

// number_format writes `v` with `decimals`, using the locale's decimal mark.
// The text is in the frame's temp memory.
number_format :: proc(t: ^Tree, v: f32, decimals: int) -> string {
	s := fmt.tprintf("%.*f", decimals, v)
	if t.locale.decimal != "." && t.locale.decimal != "" {
		if dot := strings.index_byte(s, '.'); dot >= 0 do return fmt.tprintf("%s%s%s", s[:dot], t.locale.decimal, s[dot + 1:])
	}
	return s
}

// number_step nudges by `dir` steps (× mult) and sends on_change.
number_step :: proc(ui: ^Ui($Msg), outer: Node, dir, mult: int) -> bool {
	t := &ui.tree
	sp, ok := t.spins[outer]
	if !ok || sp.step <= 0 do return false
	if od := node_get(t, outer); od != nil && .Disabled in od.flags do return false
	v := clamp(sp.value + f32(dir * mult) * sp.step, sp.min, sp.max)
	return number_commit(ui, outer, v)
}

// number_commit adopts `v`: the field shows it and on_change carries it
// when it changed.
@(private)
number_commit :: proc(ui: ^Ui($Msg), outer: Node, v: f32) -> bool {
	t := &ui.tree
	sp, ok := t.spins[outer]
	if !ok do return false
	nv := clamp(v, sp.min, sp.max)
	text_set(&sp.text, number_format(t, nv, sp.decimals))
	if fd := node_get(t, sp.field); fd != nil {
		fd.access.value = nv
		if s, has := &t.inputs[sp.field]; has do input_refresh(t, sp.field, fd, s)
		mark_paint_dirty(t, sp.field)
	}
	if nv == sp.value do return true
	sp.value = nv
	ask_rebuild(ui) // the − / + buttons enable / disable at the limits
	if h, has := ui.on_number[outer]; has do handler_send(ui, h, nv, outer)
	return true
}

// number_parse reads the field: what was typed (a comma or a point both
// count as the decimal mark), or the last value.
@(private)
number_parse :: proc(sp: ^Spin_State) -> f32 {
	s := strings.trim_space(string(sp.text.buf[:]))
	if strings.contains(s, ",") && !strings.contains(s, ".") {
		s, _ = strings.replace_all(s, ",", ".", context.temp_allocator)
	}
	if v, ok := strconv.parse_f32(s); ok do return v
	return sp.value
}

// number_key: Up / Down step (Shift ×10), Enter commits, Escape reverts.
number_key :: proc(ui: ^Ui($Msg), key: Key, mods: Mods) -> bool {
	t := &ui.tree
	outer, ok := t.spin_of[t.focus]
	if !ok do return false
	ui.spin_focused = t.focus // commit when focus leaves, even before the next event batch
	sp := t.spins[outer]
	mult := 10 if .Shift in mods else 1
	#partial switch key {
	case .Up:     return number_step(ui, outer, +1, mult)
	case .Down:   return number_step(ui, outer, -1, mult)
	case .Enter: // commit, and select the result so typing again replaces it
		done := number_commit(ui, outer, number_parse(sp))
		text_input_select_all(t, sp.field)
		return done
	case .Escape:
		if string(sp.text.buf[:]) == number_format(t, sp.value, sp.decimals) do return false // nothing to revert: Escape goes on (closing a popover)
		text_set(&sp.text, number_format(t, sp.value, sp.decimals))
		if fd := node_get(t, sp.field); fd != nil {
			if s, has := &t.inputs[sp.field]; has do input_refresh(t, sp.field, fd, s)
			mark_paint_dirty(t, sp.field)
		}
		return true
	}
	return false
}

// number_tick commits a number field when focus leaves it.
@(private)
number_tick :: proc(ui: ^Ui($Msg)) {
	t := &ui.tree
	if _, is_field := t.spin_of[t.focus]; is_field {
		ui.spin_focused = t.focus
		return
	}
	if ui.spin_focused == NODE_NONE do return
	left := ui.spin_focused
	ui.spin_focused = NODE_NONE
	if outer, ok := t.spin_of[left]; ok {
		if sp, has := t.spins[outer]; has do number_commit(ui, outer, number_parse(sp))
	}
}
