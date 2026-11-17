package baldr

// Telling the desktop what just happened. Walking the tree says what an app
// is; these say what changed, which is how a screen reader follows an app
// rather than re-reading it: focus moved here, the caret moved there, this
// text was typed, that slider is worth more now.
//
// What we watch is the focused object and the active window, looked at once
// a wake-up. That is what a reader following a keyboard is asking about, and
// it costs nothing when nothing has focus. Everything else a reader is
// holding is swept a few objects at a time (a11y_changes.odin).

import "core:strings"

// A11y_Watch is what we last told the desktop about the focused object, so
// that the next look can see what changed.
@(private)
A11y_Watch :: struct {
	id:         u64,
	text:       string, // its text as the desktop last heard it (owned)
	have_text:  bool,
	caret:      int,    // characters, as every platform's text interface counts
	sel_lo:     int,
	sel_hi:     int,
	value:      f64,
	have_value: bool,
	active:     u64, // the item its cursor is on (a list, a grid, a tree keeps focus itself)
	selected:   u64, // its selection's version, so a different set is heard, not only a different size
	has_sel:    bool,
	version:    u64, // the widget's own change counter, where it has one
	flags:      A11y_Flags,
	name:       string, // owned
	describe:   string, // owned
}

@(private)
a11y_watch_free :: proc(w: ^A11y_Watch) {
	delete(w.text)
	delete(w.name)
	delete(w.describe)
	w^ = {}
}

// FLAGS_WATCHED are the state flags worth an event when they change under
// the reader: what a control says about itself while someone is using it.
@(private)
FLAGS_WATCHED :: A11y_Flags{.Checked, .Pressed, .Selected, .Expanded, .Collapsed, .Indeterminate, .Enabled, .Sensitive, .Read_Only, .Invalid_Entry, .Required, .Busy}

// a11y_events looks at what has focus and tells the desktop what moved since
// the last look. Called once a wake-up, after the window list is current.
@(private)
a11y_events :: proc() {
	if !a11y_on() do return

	// which window is active, and what has focus in it
	active_id, focus_id: u64
	focus_window, focus_node := -1, NODE_NONE
	for w, i in a11y.windows {
		if w.tree == nil do continue
		if w.active {
			if id, ok := a11y_id(i, NODE_NONE); ok do active_id = id
			if f := w.tree.focus; f != NODE_NONE && a11y_reachable(w.tree, f) {
				if id, ok := a11y_id(i, f); ok {
					focus_id, focus_window, focus_node = id, i, f
				}
			}
		}
	}

	a11y_debug("look: windows=%d active=%d focus=%d (node %v in window %d)",
		len(a11y.windows), active_id, focus_id, focus_node, focus_window)

	if active_id != a11y.active_window {
		if a11y.active_window != 0 do a11y_say(Said_Window{id = a11y.active_window, active = false})
		if active_id != 0 {
			title := ""
			if w, _, ok := a11y_window_of(active_id); ok do title = w.title
			a11y_say(Said_Window{id = active_id, active = true, title = title})
		}
		a11y.active_window = active_id
	}

	if focus_id != a11y.watch.id {
		if a11y.watch.id != 0 do a11y_say(Said_Flag{id = a11y.watch.id, flag = .Focused, on = false})
		a11y_watch_free(&a11y.watch)
		a11y.watch.id = focus_id
		if focus_id != 0 {
			a11y_say(Said_Focus{id = focus_id})
			a11y_watch_take(focus_window, focus_node, focus_id) // its text and value are now the desktop's picture
			// a list focused with a row already under its cursor says which
			// row, as a toolkit does: the list, then the item on it
			ft := a11y.windows[focus_window].tree
			if fd := node_get(ft, focus_node); fd != nil && a11y.watch.active != 0 {
				a11y_say(Said_Active_Item{
					id = focus_id, child = a11y.watch.active,
					index = a11y_index(ft, fd.access.active),
				})
			}
		}
		a11y_sweep()
		return
	}
	if focus_id != 0 do a11y_watch_diff(focus_window, focus_node, focus_id)
	a11y_live_pass()
	a11y_sweep() // …and a few of the objects the reader is holding elsewhere
}

// a11y_live_pass says what the live regions of every window say now, when
// that is not what they said last time. It is how anything away from the
// keyboard is heard at all (a copy that started, an error elsewhere on the
// screen). The tree keeps the set, so this costs a handful of nodes rather
// than a walk.
@(private)
a11y_live_pass :: proc() {
	for w, wi in a11y.windows {
		t := w.tree
		if t == nil do continue
		for n in t.lives {
			d := node_get(t, n)
			if d == nil || !a11y_walkable(t, n) do continue
			id, ok := a11y_id(wi, n)
			if !ok do continue
			said := node_label(t, n)
			was, heard := a11y.live_said[id]
			if heard && was == said do continue
			if len(said) > 0 {
				a11y_say(Said_Announce{id = id, text = said, assertive = d.access.live == .Assertive})
			}
			if heard do delete(was)
			if len(a11y.live_said) < A11Y_LIVE_MAX || heard do a11y.live_said[id] = strings.clone(said)
		}
	}
}

// A11Y_LIVE_MAX caps what we remember having said, so a window churning
// live nodes cannot grow it without end.
@(private)
A11Y_LIVE_MAX :: 64

// a11y_live_forget drops what a window's live regions last said.
@(private)
a11y_live_forget :: proc() {
	for _, said in a11y.live_said do delete(said)
	clear(&a11y.live_said)
}

// a11y_active_id is the object id of `d`'s active item — the row its cursor
// is on — or 0 when it has none, or it is not something a reader can see.
@(private)
a11y_active_id :: proc(window: int, t: ^Tree, d: ^Node_Data) -> u64 {
	if d == nil || d.access.active == NODE_NONE || !a11y_shown(t, d.access.active) do return 0
	id, ok := a11y_id(window, d.access.active)
	return id if ok else 0
}

// a11y_selection_version is the change counter of the selection a view
// keeps, and whether it keeps one at all. A reader is told when the set
// changes — another row picked, a Ctrl+A, a band over half a grid — and a
// count alone would miss a different row of the same size.
@(private)
a11y_selection_version :: proc(t: ^Tree, n: Node) -> (u64, bool) {
	if vs, is_view := &t.icon_views[n]; is_view && vs.sel != nil do return vs.sel.version, true
	if ts, is_table := &t.tables[n]; is_table && ts.sel != nil do return ts.sel.version, true
	return 0, false
}

// a11y_window_of finds the window an id names.
@(private)
a11y_window_of :: proc(id: u64) -> (A11y_Window, int, bool) {
	w, _, ok := a11y_unpack(id)
	if !ok do return {}, 0, false
	return a11y.windows[w], w, true
}

// a11y_watch_take records the focused object as the desktop now sees it,
// without saying anything: it has just been told by the focus event.
@(private)
a11y_watch_take :: proc(window: int, n: Node, id: u64) {
	t := a11y.windows[window].tree
	d := node_get(t, n)
	if d == nil do return
	a11y.watch.flags = a11y_flags(t, n, d)
	a11y.watch.active = a11y_active_id(window, t, d)
	a11y.watch.selected, a11y.watch.has_sel = a11y_selection_version(t, n)
	a11y.watch.name = strings.clone(d.access.name)
	a11y.watch.describe = strings.clone(d.access.describe)
	if d.access.has_value {
		a11y.watch.have_value = true
		a11y.watch.value = f64(d.access.value)
	}
	if info, has := a11y_obj_text(id); has {
		a11y.watch.have_text = true
		a11y.watch.text = strings.clone(info.text)
		a11y.watch.version = a11y_text_version(t, n)
		a11y.watch.caret = a11y_char_off(info.text, info.caret)
		a11y.watch.sel_lo = a11y_char_off(info.text, info.sel_lo)
		a11y.watch.sel_hi = a11y_char_off(info.text, info.sel_hi)
	}
}

// a11y_watch_diff says what changed about the focused object since the last
// look, and remembers the new picture.
@(private)
a11y_watch_diff :: proc(window: int, n: Node, id: u64) {
	t := a11y.windows[window].tree
	d := node_get(t, n)
	if d == nil do return
	w := &a11y.watch

	if flags := a11y_flags(t, n, d); flags != w.flags {
		for f in A11y_Flag do if f in FLAGS_WATCHED && (f in flags) != (f in w.flags) {
			a11y_say(Said_Flag{id = id, flag = f, on = f in flags})
		}
		w.flags = flags
	}
	// the cursor moving inside a view that keeps the focus: focus itself has
	// not moved, so this is the only thing that says which row is current
	if active := a11y_active_id(window, t, d); active != w.active {
		if active != 0 {
			a11y_say(Said_Active_Item{id = id, child = active, index = a11y_index(t, d.access.active)})
		}
		w.active = active
	}
	if version, has := a11y_selection_version(t, n); version != w.selected || has != w.has_sel {
		if has && w.has_sel do a11y_say(Said_Selection{id = id})
		w.selected, w.has_sel = version, has
	}
	if d.access.name != w.name {
		a11y_say(Said_Name{id = id, name = d.access.name})
		delete(w.name)
		w.name = strings.clone(d.access.name)
	}
	if d.access.describe != w.describe {
		a11y_say(Said_Describe{id = id, describe = d.access.describe})
		delete(w.describe)
		w.describe = strings.clone(d.access.describe)
	}
	if d.access.has_value {
		if v := f64(d.access.value); !w.have_value || v != w.value {
			a11y_say(Said_Value{id = id, value = v})
			w.have_value, w.value = true, v
		}
	}

	info, has := a11y_obj_text(id)
	if !has do return
	// An editor says when it changed, so a document nobody is typing in is
	// not compared character by character every wake-up; a field is short
	// enough to compare.
	version := a11y_text_version(t, n)
	changed := version != w.version if version != 0 else info.text != w.text
	if changed {
		at, removed, added := a11y_text_delta(w.text, info.text)
		if removed > 0 {
			from, to := a11y_byte_off(w.text, at), a11y_byte_off(w.text, at + removed)
			// what went, so a reader can say it
			a11y_say(Said_Text_Edit{id = id, inserted = false, at = at, count = removed, text = w.text[from:to]})
		}
		if added > 0 {
			from, to := a11y_byte_off(info.text, at), a11y_byte_off(info.text, at + added)
			a11y_say(Said_Text_Edit{id = id, inserted = true, at = at, count = added, text = info.text[from:to]})
		}
		delete(w.text)
		w.text = strings.clone(info.text)
		w.have_text = true
		w.version = version
	}
	if caret := a11y_char_off(info.text, info.caret); caret != w.caret {
		a11y_say(Said_Caret{id = id, at = caret})
		w.caret = caret
	}
	lo, hi := a11y_char_off(info.text, info.sel_lo), a11y_char_off(info.text, info.sel_hi)
	if lo != w.sel_lo || hi != w.sel_hi {
		a11y_say(Said_Text_Selection{id = id})
		w.sel_lo, w.sel_hi = lo, hi
	}
}

// a11y_text_version is the widget's own change counter where it has one — a
// document's version. Zero means it has none and the text itself is what
// there is to compare.
@(private)
a11y_text_version :: proc(t: ^Tree, n: Node) -> u64 {
	if s, is_area := &t.areas[n]; is_area && s.doc != nil do return u64(s.doc.version) + 1
	if s, is_view := &t.md_views[n]; is_view && s.md != nil do return s.md.rev + 1 // a reply grows by the token
	return 0
}

// a11y_text_delta is what happened between two versions of a string, in
// characters: the first place they differ, how much went and how much came.
// It is the common prefix and suffix, which is what an edit looks like.
@(private)
a11y_text_delta :: proc(old, new: string) -> (at, removed, added: int) {
	pre := 0 // bytes in common at the front, on a rune boundary
	for pre < len(old) && pre < len(new) && old[pre] == new[pre] do pre += 1
	for pre > 0 && !a11y_rune_start(old, pre) do pre -= 1
	suf := 0 // …and at the back
	for suf < len(old) - pre && suf < len(new) - pre && old[len(old) - 1 - suf] == new[len(new) - 1 - suf] do suf += 1
	for suf > 0 && !a11y_rune_start(old, len(old) - suf) do suf -= 1
	at = a11y_char_off(old, pre)
	removed = a11y_char_off(old, len(old) - suf) - at
	added = a11y_char_off(new, len(new) - suf) - at
	return
}

@(private)
a11y_rune_start :: proc(s: string, i: int) -> bool {
	return i <= 0 || i >= len(s) || s[i] & 0xC0 != 0x80
}

// a11y_char_off is a byte offset as a character offset (every platform's
// text interface counts characters); -1 stays -1.
@(private)
a11y_char_off :: proc(s: string, b: int) -> int {
	if b < 0 do return -1
	n := 0
	for i in 0 ..< min(b, len(s)) do if s[i] & 0xC0 != 0x80 do n += 1
	return n
}

// a11y_byte_off is the other direction.
@(private)
a11y_byte_off :: proc(s: string, chars: int) -> int {
	if chars <= 0 do return 0
	n := 0
	for i in 0 ..< len(s) {
		if s[i] & 0xC0 != 0x80 {
			if n == chars do return i
			n += 1
		}
	}
	return len(s)
}
