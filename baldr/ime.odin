package baldr

// Input methods: typing Chinese, Japanese or Korean goes
// through an input method, which composes several keystrokes into text. The
// focused field tells it what it is, what is around the caret and where the
// caret is on screen; the method answers with a preedit — the composition in
// progress — text to commit, and text to delete around the caret.
//
// A preedit is never in the Document and never in undo: it is shown at the
// caret, underlined, and replaced or cleared as the method sees fit. Only a
// commit edits the text, and it edits it exactly as typing does, so it joins
// the same undo group.
//
// The platform installs `Tree.ime.hook` (app.odin, zwp_text_input_v3 on
// Wayland). Without one, everything here is inert and keys type directly.

import "core:strings"
import "core:unicode/utf8"

// Ime_Purpose is what a field is for, so an input method can suit itself to
// it: digits for a PIN, no composing in a password.
Ime_Purpose :: enum u8 { Normal, Alpha, Digits, Number, Phone, Url, Email, Name, Password, Pin, Date, Time, Datetime, Terminal }

// Ime_Hint asks an input method for a behaviour where it has the choice.
Ime_Hint :: enum u8 { Completion, Spellcheck, Auto_Capitalization, Lowercase, Uppercase, Titlecase, Hidden_Text, Sensitive_Data, Latin, Multiline }
Ime_Hints :: bit_set[Ime_Hint; u16]

// Ime_Cause says what moved the text last: the input method itself, or
// anything else (typing, a click, the app).
Ime_Cause :: enum u8 { Input_Method, Other }

// IME_SURROUNDING_MAX is how much text around the caret is sent.
IME_SURROUNDING_MAX :: 2000

// Ime_Info is what the focused field tells the input method: whether it
// wants one, what it is for, the text around the caret (never the preedit)
// with the caret and the selection anchor as byte offsets into it, and the
// caret's rectangle in window coordinates, so the candidate window sits by it.
Ime_Info :: struct {
	on:             bool,
	purpose:        Ime_Purpose,
	hints:          Ime_Hints,
	surrounding:    string,
	cursor, anchor: int,
	cause:          Ime_Cause,
	caret:          Rect,
}

// Input_Method is the platform hook the runtime installs on the tree, the
// way it installs Clipboard. `set` is called when what the field tells the
// input method changes; the backend sends what moved.
Input_Method :: struct {
	user:    rawptr,
	surface: u32, // the window the field is on, as the platform knows it
	set:     proc(user: rawptr, surface: u32, info: Ime_Info),
}

// Ime_Event is one round of changes from the input method, applied in this
// order: the preedit shown now goes, `delete_before` bytes before the caret
// and `delete_after` after it are deleted, `commit` is inserted as typed,
// and `preedit` is shown at the caret with its cursor between `cursor_begin`
// and `cursor_end` (-1 and -1: no cursor of its own).
Ime_Event :: struct {
	delete_before, delete_after: int,
	commit:                      string,
	preedit:                     string,
	cursor_begin, cursor_end:    int,
}

// Ime is the tree's composition state: which field is composing, what it
// shows, and what was last told to the input method.
Ime :: struct {
	hook:      Input_Method,
	node:      Node,   // the field showing a preedit (NODE_NONE: none)
	text:      string, // the preedit itself (tree allocator)
	lo, hi:    int,    // the input method's cursor inside `text`; both -1: hidden
	cause:     Ime_Cause,
	sent:      Ime_Info,
	sent_text: string, // sent.surrounding, ours
}

// ime_preedit is what the field `n` is composing, if anything: the text and
// the input method's cursor inside it.
@(private)
ime_preedit :: proc(t: ^Tree, n: Node) -> (text: string, lo, hi: int, ok: bool) {
	if t.ime.node != n || len(t.ime.text) == 0 do return "", -1, -1, false
	return t.ime.text, t.ime.lo, t.ime.hi, true
}

// ime_keep copies the preedit for `n` into a widget's own state, so what is
// drawn cannot outlive the tree's copy. True when it changed.
@(private)
ime_keep :: proc(t: ^Tree, n: Node, dst: ^string, lo, hi: ^int) -> bool {
	text, l, h, _ := ime_preedit(t, n)
	if dst^ == text && lo^ == l && hi^ == h do return false
	if len(dst^) > 0 do delete(dst^, t.allocator)
	dst^ = strings.clone(text, t.allocator) if len(text) > 0 else ""
	lo^, hi^ = l, h
	return true
}

// ime_moved: the text or the caret moved for a reason of ours (typing, a
// click, the app), so the input method hears about it on the next sync.
@(private)
ime_moved :: proc(t: ^Tree, cause: Ime_Cause = .Other) {
	t.ime.cause = cause
}

// ime_clear takes away the preedit shown now, if any, and asks for a
// repaint and a fresh layout of the field that had it.
@(private)
ime_clear :: proc(t: ^Tree) {
	if t.ime.node == NODE_NONE && len(t.ime.text) == 0 do return
	n := t.ime.node
	if len(t.ime.text) > 0 do delete(t.ime.text, t.allocator)
	t.ime = {hook = t.ime.hook, node = NODE_NONE, lo = -1, hi = -1, cause = t.ime.cause, sent = t.ime.sent, sent_text = t.ime.sent_text}
	if node_get(t, n) != nil {
		if s, ok := &t.areas[n]; ok {
			s.tops_valid = false
			mark_layout_dirty(t, n)
		}
		mark_paint_dirty(t, n)
	}
}

// ime_show puts a preedit on the focused field.
@(private)
ime_show :: proc(t: ^Tree, n: Node, text: string, lo, hi: int) {
	ime_clear(t)
	if len(text) == 0 || node_get(t, n) == nil do return
	t.ime.node = n
	t.ime.text = strings.clone(text, t.allocator)
	t.ime.lo, t.ime.hi = lo, hi
	if s, ok := &t.areas[n]; ok {
		s.tops_valid = false
		mark_layout_dirty(t, n)
	}
	mark_paint_dirty(t, n)
}

// ime_apply performs one round from the input method on the focused field
// (see Ime_Event). It returns true when anything changed, so the runtime
// knows to draw. A field that takes no input methods ignores it.
ime_apply :: proc(ui: ^Ui($Msg), ev: Ime_Event) -> bool {
	t := &ui.tree
	n := t.focus
	had := t.ime.node != NODE_NONE || len(t.ime.text) > 0
	ime_clear(t)
	if node_get(t, n) == nil do return had
	did := had
	if ev.delete_before > 0 || ev.delete_after > 0 {
		if ime_delete_around(ui, n, ev.delete_before, ev.delete_after) do did = true
	}
	if len(ev.commit) > 0 {
		if ime_insert(ui, n, ev.commit) do did = true
	}
	if len(ev.preedit) > 0 {
		ime_show(t, n, ev.preedit, ev.cursor_begin, ev.cursor_end)
		did = true
	}
	ime_moved(t, .Input_Method)
	if did do ask_rebuild(ui) // the field draws the composition from its own copy
	return did
}

// ime_insert commits the input method's text into the focused field, as
// typing does (one undo group with the typing around it).
@(private)
ime_insert :: proc(ui: ^Ui($Msg), n: Node, text: string) -> bool {
	if term_commit(ui, n, text) do return true // a terminal: the program gets it as typed
	if text_area_commit(ui, n, text) do return true
	return input_put(ui, n, text)
}

// ime_delete_around deletes `before` bytes before the selection and `after`
// after it, as the input method asked (the selection itself stays: the
// commit replaces it, as typing would).
@(private)
ime_delete_around :: proc(ui: ^Ui($Msg), n: Node, before, after: int) -> bool {
	if text_area_delete_around(ui, n, before, after) do return true
	return text_input_delete_around(ui, n, before, after)
}

// ime_sync tells the input method what the focused field is, what is around
// its caret and where the caret is, whenever any of it changes. Called once
// after events, so a frame sends at most one round.
@(private)
ime_sync :: proc(ui: ^Ui($Msg)) {
	t := &ui.tree
	if t.ime.node != NODE_NONE && t.ime.node != t.focus { // focus left the field mid-composition: it goes
		ime_clear(t)
		ask_rebuild(ui)
	}
	if t.ime.hook.set == nil do return
	info := ime_info(t)
	if info == t.ime.sent do return
	t.ime.hook.set(t.ime.hook.user, t.ime.hook.surface, info)
	delete(t.ime.sent_text, t.allocator)
	t.ime.sent_text = strings.clone(info.surrounding, t.allocator)
	t.ime.sent = info
	t.ime.sent.surrounding = t.ime.sent_text
	t.ime.cause = .Other
}

// ime_info reads the focused field's state for the input method.
@(private)
ime_info :: proc(t: ^Tree) -> (info: Ime_Info) {
	n := t.focus
	d := node_get(t, n)
	if d == nil || .Disabled in d.flags do return
	info.cause = t.ime.cause
	if s, ok := &t.inputs[n]; ok {
		if s.password { // a password takes no input method: nothing to compose, nothing to learn
			info.purpose = .Password
			info.hints = {.Sensitive_Data, .Hidden_Text}
			return
		}
		info.on = true
		src := input_src(s)
		info.surrounding, info.cursor, info.anchor = ime_window(src, s.caret, s.anchor)
		info.caret = input_caret_rect(t, n, d, s)
		return
	}
	if st, ok := &t.terminals[n]; ok {
		// a terminal composes at its cursor; what is around it is the
		// program's, and not something to hand an input method
		info.on = true
		info.purpose = .Terminal
		info.caret = term_caret_rect(t, n, d, st)
		return
	}
	if s, ok := &t.areas[n]; ok && s.doc != nil {
		if s.readonly do return
		info.on = true
		info.hints = {.Multiline}
		if !s.code.on do info.hints += {.Spellcheck}
		line := block_str(s.doc, s.caret.block)
		anchor := s.caret.off
		if s.anchor.block == s.caret.block {
			anchor = s.anchor.off
		} else if s.anchor.block < s.caret.block {
			anchor = 0
		} else {
			anchor = len(line)
		}
		info.surrounding, info.cursor, info.anchor = ime_window(line, s.caret.off, anchor)
		info.caret = area_caret_rect(t, n, d, s)
		return
	}
	return
}

// ime_window is the text around the caret an input method is told about,
// cut to IME_SURROUNDING_MAX bytes on character boundaries, with the caret
// and the anchor moved into it.
@(private)
ime_window :: proc(text: string, cursor, anchor: int) -> (out: string, c, a: int) {
	c, a = clamp(cursor, 0, len(text)), clamp(anchor, 0, len(text))
	if len(text) <= IME_SURROUNDING_MAX do return text, c, a
	lo, hi := min(c, a), max(c, a)
	room := IME_SURROUNDING_MAX - min(hi - lo, IME_SURROUNDING_MAX)
	start := max(lo - room / 2, 0)
	end := min(start + IME_SURROUNDING_MAX, len(text))
	start = max(end - IME_SURROUNDING_MAX, 0)
	for start > 0 && start < len(text) && !utf8.rune_start(text[start]) do start -= 1
	for end < len(text) && !utf8.rune_start(text[end]) do end += 1
	return text[start:end], clamp(c - start, 0, end - start), clamp(a - start, 0, end - start)
}

// ime_byte_before / ime_byte_after: `n` bytes back from `at` (or forward),
// pulled onto a character boundary, so a method counting in bytes can't
// split one.
@(private)
ime_byte_before :: proc(text: string, at, n: int) -> int {
	i := clamp(at - n, 0, len(text))
	for i > 0 && i < len(text) && !utf8.rune_start(text[i]) do i -= 1
	return i
}

@(private)
ime_byte_after :: proc(text: string, at, n: int) -> int {
	i := clamp(at + n, 0, len(text))
	for i < len(text) && !utf8.rune_start(text[i]) do i += 1
	return i
}
