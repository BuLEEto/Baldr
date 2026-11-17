package baldr

// Type-ahead in tables and icon views: with the view focused
// and no field focused, typing selects the first row whose label starts with
// what was typed. Letters within TYPE_AHEAD_MS build the prefix; the same
// letter again steps to the next row starting with it, wrapping. The match
// is selected and scrolled into view. The app gives the labels through
// `label_of`, since rows off screen have no nodes to read.

import "core:unicode"
import "core:unicode/utf8"

// Label_Of gives row `index`'s label (a file's name) for type-ahead.
Label_Of :: proc(user: rawptr, index: int) -> string

TYPE_AHEAD_MS :: 700.0

@(private)
Type_Ahead :: struct {
	view: Node,
	buf:  [64]u8,
	n:    int,
	at:   f64,
}

// type_ahead_text takes typed text for a focused table or icon view that has
// labels. True when it did (a focused view with labels keeps what is typed,
// matched or not).
@(private)
type_ahead_text :: proc(ui: ^Ui($Msg), text: string) -> bool {
	t := &ui.tree
	view := t.focus
	label_of: Label_Of
	user: rawptr
	count: int
	sel: ^Selection
	is_table := false
	if ts, ok := t.tables[view]; ok {
		label_of, user, count, sel, is_table = ts.label_of, ts.label_user, ts.count, ts.sel, true
	} else if vs, vok := t.icon_views[view]; vok {
		label_of, user, count, sel = vs.label_of, vs.label_user, vs.count, vs.sel
	}
	if label_of == nil || sel == nil || count == 0 do return false
	blank := true
	for r in text do if !unicode.is_space(r) { blank = false; break }
	if blank do return false // Space selects; a blank never starts a prefix
	ta := &ui.type_ahead
	if ta.view != view || t.now_ms - ta.at > TYPE_AHEAD_MS do ta.n = 0
	ta.view, ta.at = view, t.now_ms
	for b in transmute([]u8)text {
		if ta.n >= len(ta.buf) do break
		ta.buf[ta.n] = b
		ta.n += 1
	}
	prefix := string(ta.buf[:ta.n])
	first, first_w := utf8.decode_rune_in_string(prefix)
	repeated := utf8.rune_count_in_string(prefix) > 1
	for r in prefix do if r != first { repeated = false; break }
	want, from := prefix, 0
	if repeated do want, from = prefix[:first_w], sel.cursor + 1 // the same letter again: the next row starting with it
	idx := -1
	for k in 0 ..< count {
		i := (from + k) % count
		if label_has_prefix(label_of(user, i), want) {
			idx = i
			break
		}
	}
	if idx < 0 do return true
	selection_set(sel, idx)
	if is_table { table_reveal(ui, view, idx) } else { icon_view_reveal(ui, view, idx) }
	grid_selection_changed(ui, view)
	return true
}

// label_has_prefix compares case-insensitively, rune by rune.
@(private)
label_has_prefix :: proc(label, prefix: string) -> bool {
	li := 0
	for pr in prefix {
		if li >= len(label) do return false
		lr, w := utf8.decode_rune_in_string(label[li:])
		if unicode.to_lower(lr) != unicode.to_lower(pr) do return false
		li += w
	}
	return true
}
