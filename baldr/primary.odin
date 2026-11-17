package baldr

// The primary selection in text fields and editors: what someone selects
// becomes what a middle click pastes, anywhere on the desktop, and a middle
// click in a field pastes it there — as every Linux toolkit and terminal
// does (a terminal takes part through copy_text / paste with `primary`).
//
// Only a selection the person made counts: a press, a drag, a double or
// triple click, Shift with a movement key, Ctrl+A. A field that selects its
// own value (after Enter commits it, or when the app hands it focus) does
// not take the primary selection from whoever had it. A password field
// never gives its text away; it may still be pasted into.

import "core:mem"
import "core:strings"

// primary_mark says the person just changed the selection in field `n`: it
// goes to the primary selection at the end of this wake (primary_sync).
// `fresh`: a new press, so the same text selected again is sent again.
@(private)
primary_mark :: proc(t: ^Tree, n: Node, fresh := false) {
	t.primary_pending = n
	if fresh && len(t.primary_sent) > 0 {
		delete(t.primary_sent, t.allocator)
		t.primary_sent = ""
	}
}

// primary_sync gives the primary selection what the person selected, once
// a wake, when it changed.
@(private)
primary_sync :: proc(ui: ^Ui($Msg)) {
	t := &ui.tree
	n := t.primary_pending
	if n == NODE_NONE do return
	t.primary_pending = NODE_NONE
	if t.clipboard.primary_set == nil do return
	text := primary_text_of(t, n)
	if len(text) == 0 || text == t.primary_sent do return
	if !t.clipboard.primary_set(t.clipboard.user, text) do return
	delete(t.primary_sent, t.allocator)
	t.primary_sent = strings.clone(text, t.allocator)
}

// primary_text_of is what field `n` has selected (the frame's temp memory;
// "" for none, and always for a password).
@(private)
primary_text_of :: proc(t: ^Tree, n: Node) -> string {
	if s, ok := &t.inputs[n]; ok {
		if s.password || s.value == nil do return ""
		lo, hi := min(s.caret, s.anchor), max(s.caret, s.anchor)
		src := input_src(s)
		if lo == hi || hi > len(src) do return ""
		return src[lo:hi]
	}
	if s, ok := &t.areas[n]; ok && s.doc != nil {
		lo, hi := pos_order(s.caret, s.anchor)
		if lo == hi do return ""
		return document_range_text(s.doc, lo, hi, context.temp_allocator)
	}
	return ""
}

// primary_paste is a middle press at `pos`: over an editable field it puts
// the caret there and types the primary selection. False when no field
// takes it (the press goes on to a middle-click message).
@(private)
primary_paste :: proc(ui: ^Ui($Msg), pos: [2]f32) -> bool {
	t := &ui.tree
	if t.clipboard.primary_get == nil do return false
	if n, d, s, ok := area_at(ui, pos); ok {
		if s.readonly do return false
		set_focus(t, n, false)
		p := area_hit(t, n, d, s, pos)
		s.caret, s.anchor, s.goal_x = p, p, -1
		pasted, got := t.clipboard.primary_get(t.clipboard.user, context.temp_allocator)
		if clean := sanitize_multiline(pasted); got && len(clean) > 0 {
			area_replace(ui, n, s, p, p, clean)
		} else {
			area_touch(t, n, s)
		}
		return true
	}
	if n, d, s, ok := input_at(ui, pos); ok {
		if .Disabled in d.flags || s.value == nil do return false
		set_focus(t, n, false)
		b := input_hit_src(t, d, s, pos.x)
		s.caret, s.anchor = b, b
		pasted, got := t.clipboard.primary_get(t.clipboard.user, context.temp_allocator)
		clean := sanitize_input(pasted)
		if got && len(clean) > 0 {
			input_replace(ui, n, d, s, b, b, clean)
		} else {
			input_touch(t, n, s)
		}
		if s.password { // the pasted passphrase's scratch copies, as Ctrl+V leaves them
			if raw_data(clean) != raw_data(pasted) do mem.zero(raw_data(clean), len(clean))
			mem.zero(raw_data(pasted), len(pasted))
		}
		return true
	}
	return false
}
