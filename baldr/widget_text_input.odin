package baldr

// text_input: a single-line editable field over an app-owned Text buffer.
//
// The node is a leaf of kind Text_Input_Kind. Its editing state (caret,
// selection anchor, horizontal scroll, blink clock, the string actually drawn)
// lives in the Tree side table `inputs`, so the hot node stays small and the
// state survives reconciliation and keyed moves. The app's Msg-typed handlers
// live beside it in Ui.input_handlers.
//
// Everything is byte offsets into the buffer, always on a grapheme boundary
// (text_edit.odin). Caret x positions and click hit-testing use the same runa
// line layout render_text draws with, so the caret sits exactly between the
// glyphs it is between. Without a Text_Engine (headless default) the mono
// measurer's fixed advance is used instead, so the widget still lays out,
// paints, and hit-tests deterministically.

import "core:mem"
import "core:strings"
import "core:unicode/utf8"
import runa "baldr:third_party/runa"

// Text_Input_Kind marks a text_input node. The data is in Tree.inputs.
Text_Input_Kind :: struct {}

// TEXT_INPUT_MIN_WIDTH is the narrowest a field goes when a row runs out of
// room (a few characters stay visible; the row's other children shrink).
TEXT_INPUT_MIN_WIDTH :: f32(96)

// TEXT_INPUT_DEFAULT_WIDTH is the field's intrinsic width (logical px) when
// neither `width` nor `flex` nor the parent's stretch decides it.
TEXT_INPUT_DEFAULT_WIDTH :: f32(240)

// MULTI_CLICK_MS / MULTI_CLICK_PX: a press this soon and this close to the
// previous one counts as a double (then triple) click.
MULTI_CLICK_MS :: 400.0
MULTI_CLICK_PX :: f32(4)

// PASSWORD_BULLET replaces every grapheme cluster when password = true.
PASSWORD_BULLET :: "•"

// Text_Input_State is the per-field editing state (Tree.inputs side table).
Text_Input_State :: struct {
	value:          ^Text,   // the app's buffer; edited in place
	own:            ^Text,   // the field's own buffer when the builder got nil (freed with the node)
	compact:        bool,    // an editor standing in for a label: tight padding, no minimum width
	quiet:          bool,    // draws no frame of its own: whatever holds it draws the chrome (a search_field)
	search:         bool,    // a search_field's input: Escape clears it before it goes anywhere else
	paste_prefer:   Paste_Prefer, // which wins when the clipboard offers a picture and text
	// Undo and redo: what the field held before each step, coalesced so a
	// typed word is one step. Never for a password: a history of a secret is
	// a copy of it.
	undo:       [dynamic]Input_Step,
	redo:       [dynamic]Input_Step,
	undo_open:  bool, // the newest step is still taking typed characters
	undo_at_ms: f64,  // …and when it last took one
	caret:          int,     // byte offset in value, on a grapheme boundary
	anchor:         int,     // selection anchor; == caret when nothing is selected
	scroll_x:       f32,     // content scroll so the caret stays visible (logical px)
	display:        string,  // what is drawn: the buffer's contents, or bullets (owned, tree allocator)
	placeholder:    string,  // owned, tree allocator
	size:           f32,     // font size, logical px
	weight:         Font_Weight, // the field's text weight and family, from Field_Look: measuring and drawing must agree
	family:         Family_Id,
	tabular:        bool,    // figures of one width (tnum): a sum, an amount, anything that changes as it is typed
	password:       bool,
	max_length:     int,     // 0 = unlimited; counts characters, not bytes
	blink_start:    f64,     // tree clock when the caret was last forced visible
	was_focused:    bool,    // paint's memory of focus, to restart the blink on focus-in
	dragging:       bool,    // a press inside the field is extending the selection
	clicks:         int,     // 1 single, 2 double (word), 3 triple (all)
	last_click_ms:  f64,
	last_click_pos: [2]f32,
	focus_asked:    bool,    // the builder's `focus` last build: focus is taken when it turns true
	focus_sel:      bool,    // the selection is the one focus made, not one the person made: Escape is not its to eat
	pre:            string,  // an input method's preedit, shown at `pre_at` in `display`; never in the buffer (ime.odin)
	pre_at:         int,     // buffer offset it sits at
	pre_lo, pre_hi: int,     // the input method's cursor inside `pre`; both -1: hidden
	caps:           bool,    // a password field with Caps Lock on: its sign shows while it has the keyboard
	caps_said:      bool,    // …and its description says so (set by the field, taken back by it)
}

// Key_Press is a key a text field passed on to its app through `on_key`,
// with the modifiers held.
Key_Press :: struct {
	key:  Key,
	mods: Mods,
}

// Text_Handlers are a field's app handlers (Ui.input_handlers side table).
Text_Handlers :: struct($Msg: typeid) {
	on_change, on_submit: Handler(Msg, string),
	on_cancel: Maybe(Msg),              // Escape
	on_key:    Handler(Msg, Key_Press), // keys the field does not use (key_offered): a list below it walked and acted on
}

// text_input is a single-line text field editing `value` in place. Typing
// queues `on_change` with the new contents; Enter queues `on_submit`.
// Keyboard: Left/Right by grapheme, Ctrl+Left/Right by word, Home/End,
// Shift extends the selection, Ctrl+A/C/X/V, Backspace/Delete (Ctrl: by
// word), Escape clears the selection. Pointer: click places the caret, drag
// selects, double-click selects a word, triple-click all. `label` is the
// accessible name (else the placeholder is used; the lint flags a field with
// neither). `password` draws bullets but edits the real buffer, never copies
// or cuts to the clipboard, and makes the buffer `secret`. `width` fixes
// the width; `flex` shares the parent's free space; otherwise the field
// stretches to its parent or takes TEXT_INPUT_DEFAULT_WIDTH.
// `focus` takes the keyboard focus when it turns true (a path bar opening, a
// filter shortcut) with the value selected, so the first thing typed
// replaces it and Right or End keeps it to edit instead. `on_cancel` is what Escape sends;
// `on_key` hears the keys a field does not use, with their modifiers, so a
// list below it can be walked and acted on: Up, Down, Page Up and Page Down,
// Shift+Delete (without `on_key` it deletes), Enter with a modifier, and
// Ctrl or Alt with a character key other than Ctrl+A, C, X, V, Z and Y. A
// Ctrl or Alt chord the window binds with `shortcut` stays the window's, as
// do Alt and Super with an arrow or Page key.
//
// A plain Enter is always `on_submit`'s; with Shift, Ctrl or Alt it goes to
// `on_key`, since `Ev(string)` carries no modifiers (a find bar's next vs
// previous match). Without `on_key` a modified Enter submits; one the window
// bound with `shortcut` is the window's either way.
// `on_paste_other` hears a Ctrl+V that found no text but a picture or files
// on the clipboard, so the field can attach them; a paste with text is
// untouched.
// A nil `value` gives the field a buffer of its own, seeded with `initial`
// on its first build (a form that only wants the text on submit; the
// inline editors); `compact` is the tight look of an editor standing in
// for a label.
text_input :: proc(ui: ^Ui($Msg), value: ^Text, placeholder: string = "", on_change: Handler(Msg, string) = nil,
	on_submit: Handler(Msg, string) = nil, label: string = "", width: f32 = 0, flex: f32 = 0, disabled := false,
	password := false, initial: string = "", compact := false, quiet := false, on_cancel: Maybe(Msg) = nil, on_key: Handler(Msg, Key_Press) = nil,
	on_paste_other: Handler(Msg, Paste_Other) = nil, max_length: int = 0,
	on_context: Handler(Msg, Editor_Context) = nil, paste_prefer: Paste_Prefer = .Text,
	tabular := false,
	focus := false, tag: u64 = 0, key: u64 = 0, loc := #caller_location) -> Node {
	n, created := reconcile_child(ui, .Text_Input, key, loc)
	t := &ui.tree
	lk := field_look(&t.theme)
	d := node_get(t, n)
	if created {
		d.access.role = .Text_Input
		d.flags += {.Focusable}
		t.inputs[n] = Text_Input_State{}
	}
	if compact {
		set_layout(t, n, Layout_Props{width = width, flex = flex if flex > 0 else 1, padding = lk.compact.padding})
	} else {
		set_layout(t, n, Layout_Props{width = width, flex = flex, min_w = TEXT_INPUT_MIN_WIDTH if width == 0 else 0,
			min_h = lk.min_height, padding = lk.padding})
	}
	st := d.style
	st.bg = {} if quiet else lk.fill
	st.fg = lk.ink
	st.radius = lk.radius
	st.border_w = 0 // paint_text_input draws the border (its colour follows focus)
	st.border = {}
	set_style(t, n, st)
	d = node_get(t, n)
	d.tag = tag
	set_name(t, n, label if label != "" else placeholder)
	set_disabled(t, n, disabled) // not by hand: it is what repaints the field when that changed
	s := &t.inputs[n]
	if value == nil && s.own == nil {
		s.own = new(Text, t.allocator)
		s.own^ = text_make(initial, t.allocator)
	}
	s.value = value if value != nil else s.own
	if password do s.value.secret = true // outgrown blocks and dropped bytes are zeroed
	if s.quiet != quiet {
		s.quiet = quiet
		mark_paint_dirty(t, n)
	}
	// A quiet field's focus is shown by whatever holds it (a `search_field`
	// turns its frame to the accent), so a ring on the inner node would be a
	// second indication. No hover wash either, as `quiet` means everywhere:
	// it answers the pointer with the I-beam, and a wash on the inner node
	// alone would cover only part of the control.
	if quiet {
		d.flags += {.Ring_Inside, .Quiet}
	} else {
		d.flags -= {.Ring_Inside, .Quiet}
	}
	s.compact = compact
	s.max_length = max(max_length, 0)
	s.paste_prefer = paste_prefer
	// The same map an editor's on_context uses, so a field and an editor
	// offer the menu the same way.
	if handler_live(on_context) { ui.editor_contexts[n] = on_context } else { delete_key(&ui.editor_contexts, n) }
	st.radius = lk.compact.radius if compact else lk.radius
	set_style(t, n, st)
	if s.password != password {
		s.password = password
		mark_paint_dirty(t, n)
	}
	// A password field says when Caps Lock is on: a sign at its end while it
	// has the keyboard, and in its description for a screen reader. The app's
	// own description is set after this, so it wins.
	caps := password && .Caps in t.keyboard.locks
	if caps != s.caps {
		s.caps = caps
		mark_paint_dirty(t, n)
	}
	if caps {
		set_describe(t, n, "Caps Lock is on")
		s.caps_said = true
	} else if s.caps_said {
		set_describe(t, n, "")
		s.caps_said = false
	}
	family := lk.text_family if lk.family_name == "" else look_family(t, lk.family_name)
	if s.size != lk.text_size || s.weight != lk.text_weight || s.family != family {
		s.size, s.weight, s.family = lk.text_size, lk.text_weight, family
		mark_layout_dirty(t, n)
	}
	if s.tabular != tabular {
		s.tabular = tabular
		mark_layout_dirty(t, n)
	}
	if s.placeholder != placeholder {
		delete(s.placeholder, t.allocator)
		s.placeholder = strings.clone(placeholder, t.allocator)
		mark_paint_dirty(t, n)
	}
	if focus && !s.focus_asked && !disabled { // it turned true: the path bar opening, a filter shortcut
		// Handed over by the app, not reached with Tab: the value is selected
		// so the first thing typed replaces it (Ctrl+L in a file manager). A
		// caret at the end would append to a path whose start is scrolled
		// out of sight.
		s.anchor = 0
		s.caret = len(input_src(s))
		s.focus_sel = true
		ui.pending_focus = n
	}
	s.focus_asked = focus
	input_refresh(t, n, d, s)
	ui.input_handlers[n] = Text_Handlers(Msg){on_change = on_change, on_submit = on_submit, on_cancel = on_cancel, on_key = on_key}
	if handler_live(on_paste_other) { ui.paste_others[n] = on_paste_other } else { delete_key(&ui.paste_others, n) }
	return n
}

// text_input_state returns a field's editing state (nil for any other node).
// Read-only for callers; tests use it to inspect the caret and selection.
// The pointer is into the tree's own storage: good until the next build.
text_input_state :: proc(t: ^Tree, n: Node) -> ^Text_Input_State {
	if node_get(t, n) == nil do return nil
	s, ok := &t.inputs[n]
	return s if ok else nil
}

// text_input_selection returns the selected byte range [lo, hi) of a field.
text_input_selection :: proc(t: ^Tree, n: Node) -> (lo, hi: int) {
	s := text_input_state(t, n)
	if s == nil do return
	return min(s.caret, s.anchor), max(s.caret, s.anchor)
}

// text_input_select_all selects the whole text of a field, so the next
// typing replaces it. Every field that commits a value on Enter (number,
// hex) does this to show the commit; focus stays, Tab still moves on.
text_input_select_all :: proc(t: ^Tree, n: Node) {
	s := text_input_state(t, n)
	if s == nil || s.value == nil do return
	s.anchor = 0
	s.caret = len(s.value.buf)
	input_touch(t, n, s)
	mark_paint_dirty(t, n)
}

// text_input_set_selection selects from `anchor` to `caret` (the end typing
// goes at); pass one offset twice to move the caret with nothing selected.
// Byte offsets into the field's value, clamped and snapped to grapheme
// boundaries; the sorted pair from `text_input_selection` restores a
// selection. Focus does not move, so a keypad beside a field can place the
// caret without taking the keyboard; the next paint scrolls the caret into
// view and the accessibility bus hears that it moved. Moving the caret is
// not editing, so a disabled field takes this too.
//
// Call it (and `text_input_insert`) from `view`, not `update`, which has no
// tree: record the key press in app state and act on it in the `view` of
// the same wake-up.
text_input_set_selection :: proc(t: ^Tree, n: Node, anchor, caret: int) {
	s := text_input_state(t, n)
	if s == nil || s.value == nil do return
	src := input_src(s)
	s.anchor = grapheme_snap(src, clamp(anchor, 0, len(src)))
	s.caret = grapheme_snap(src, clamp(caret, 0, len(src)))
	input_touch(t, n, s)
}

// text_input_insert puts `text` into the field `n` at the caret, exactly as
// typing it would: what is selected is replaced, the caret ends up after
// it, `max_length` caps it on a grapheme boundary, control characters and
// newlines are dropped, `on_change` fires, and the edit joins the field's
// undo journal. False when `n` is no field, or is disabled.
//
// Use it for a keypad, a palette or an emoji button rather than editing the
// `Text` directly: an edit the journal never saw makes Ctrl+Z restore a
// state that never existed. Each call is its own undo step, never coalesced
// with typing. An empty `text` deletes the selection, which is how a
// keypad's Backspace is written (select the grapheme before the caret with
// `text_input_set_selection`, then insert nothing); an input method's empty
// commit, by contrast, is dropped.
text_input_insert :: proc(ui: ^Ui($Msg), n: Node, text: string) -> bool {
	return input_put(ui, n, text, empty_clears = true, own_step = true)
}

// ---------------------------------------------------------------- lifecycle (node.odin hooks)

// text_input_free drops the side-table state of a node being freed.
text_input_free :: proc(t: ^Tree, n: Node) {
	if s, ok := &t.inputs[n]; ok {
		input_undo_destroy(t, s)
		delete(s.display, t.allocator)
		delete(s.placeholder, t.allocator)
		if len(s.pre) > 0 do delete(s.pre, t.allocator)
		if s.own != nil {
			text_destroy(s.own)
			free(s.own, t.allocator)
		}
		delete_key(&t.inputs, n)
	}
}

// text_inputs_destroy frees every field's state with the tree.
text_inputs_destroy :: proc(t: ^Tree) {
	for _, &s in t.inputs {
		input_undo_destroy(t, &s)
		delete(s.display, t.allocator)
		delete(s.placeholder, t.allocator)
		if len(s.pre) > 0 do delete(s.pre, t.allocator)
		if s.own != nil {
			text_destroy(s.own)
			free(s.own, t.allocator)
		}
	}
	delete(t.inputs)
}

// ---------------------------------------------------------------- state sync

// input_refresh brings the drawn string and the a11y value in step with the
// buffer (the app may have edited it in `update`) and pulls the caret and
// anchor back onto grapheme boundaries inside it.
@(private)
input_refresh :: proc(t: ^Tree, n: Node, d: ^Node_Data, s: ^Text_Input_State) {
	src := input_src(s)
	shown := src
	if s.password {
		count := grapheme_count(src)
		b := strings.builder_make(0, count * len(PASSWORD_BULLET), context.temp_allocator)
		for _ in 0 ..< count do strings.write_string(&b, PASSWORD_BULLET)
		shown = strings.to_string(b)
	}
	// an input method's composition shows at the caret, in the drawn string only
	ime_keep(t, n if !s.password else NODE_NONE, &s.pre, &s.pre_lo, &s.pre_hi)
	s.pre_at = clamp(s.caret, 0, len(src))
	if len(s.pre) > 0 {
		at := clamp(s.pre_at, 0, len(shown))
		shown = strings.concatenate({shown[:at], s.pre, shown[at:]}, context.temp_allocator)
	}
	if shown != s.display {
		delete(s.display, t.allocator)
		s.display = strings.clone(shown, t.allocator)
		mark_paint_dirty(t, n)
	}
	d.access.value_text = s.display
	s.caret = grapheme_snap(src, clamp(s.caret, 0, len(src)))
	s.anchor = grapheme_snap(src, clamp(s.anchor, 0, len(src)))
}

@(private)
input_src :: proc(s: ^Text_Input_State) -> string {
	return str(s.value^) if s.value != nil else ""
}

// input_touch: the caret moved or the text changed — restart the blink
// (visible) and repaint.
@(private)
input_touch :: proc(t: ^Tree, n: Node, s: ^Text_Input_State) {
	s.blink_start = t.now_ms
	s.focus_sel = false // the person has touched it: what is selected is theirs now
	mark_paint_dirty(t, n)
}

// input_display_off maps a buffer offset to an offset in the drawn string
// (identity unless password mode substitutes bullets).
@(private)
input_display_off :: proc(s: ^Text_Input_State, src: string, b: int) -> int {
	db := b if !s.password else grapheme_index(src, b) * len(PASSWORD_BULLET)
	if len(s.pre) > 0 && b > s.pre_at do db += len(s.pre) // past the composition
	return db
}

// input_caret_display is where the caret is drawn: inside the composition,
// at the input method's cursor, or at its end when it hides it.
@(private)
input_caret_display :: proc(s: ^Text_Input_State, src: string) -> int {
	at := input_display_off(s, src, s.caret)
	if len(s.pre) == 0 do return at
	if s.pre_lo >= 0 && s.pre_lo <= len(s.pre) do return at + s.pre_lo
	return at + len(s.pre)
}

// input_src_off is the inverse of input_display_off.
@(private)
input_src_off :: proc(s: ^Text_Input_State, src: string, db: int) -> int {
	db := db
	if len(s.pre) > 0 { // inside the composition: the caret's own offset
		start := input_display_off(s, src, s.pre_at)
		if db <= start {
			// before it
		} else if db >= start + len(s.pre) {
			db -= len(s.pre)
		} else {
			return s.pre_at
		}
	}
	if !s.password do return db
	return grapheme_offset(src, db / len(PASSWORD_BULLET))
}

// input_caret_rect is the caret's rectangle in window coordinates, for an
// input method's candidate window (ime.odin).
@(private)
input_caret_rect :: proc(t: ^Tree, n: Node, d: ^Node_Data, s: ^Text_Input_State) -> Rect {
	inner := input_inner(d)
	lh := input_line_height(t, s.size, s.family)
	x := inner.x - s.scroll_x + input_caret_x(t, s, input_caret_display(s, input_src(s)))
	return {clamp(x, inner.x, inner.x + inner.w), inner.y + max((inner.h - lh) / 2, 0), field_look(&t.theme).caret_width, lh}
}

// input_put puts text into the field `n` as typing does — an input
// method's commit (ime.odin) and an app's own insert
// (text_input_insert) are the same act, so they are the same code. False
// when `n` is no field, or is disabled.
@(private)
input_put :: proc(ui: ^Ui($Msg), n: Node, text: string, empty_clears := false, own_step := false) -> bool {
	t := &ui.tree
	d := node_get(t, n)
	s, ok := &t.inputs[n]
	if !ok || d == nil || s.value == nil || .Disabled in d.flags do return false
	clean := sanitize_input(text)
	// Nothing to put in: an input method's empty commit means nothing at
	// all, while an app's empty insert means "replace what is selected with
	// nothing" — the two callers want opposite things from the same string.
	if len(clean) == 0 && !empty_clears do return true
	input_replace(ui, n, d, s, s.anchor, s.caret, clean, own_step)
	return true
}

// text_input_delete_around deletes bytes either side of the field's
// selection, as an input method asked. False when `n` is no field.
@(private)
text_input_delete_around :: proc(ui: ^Ui($Msg), n: Node, before, after: int) -> bool {
	t := &ui.tree
	d := node_get(t, n)
	s, ok := &t.inputs[n]
	if !ok || d == nil || s.value == nil || .Disabled in d.flags do return false
	input_fit(s)
	src := input_src(s)
	lo, hi := min(s.caret, s.anchor), max(s.caret, s.anchor)
	a := ime_byte_before(src, lo, before)
	b := ime_byte_after(src, hi, after)
	kept := strings.clone(src[lo:hi], context.temp_allocator) // the selection stays: a commit replaces it, as typing would
	if a == lo && b == hi do return true
	input_replace(ui, n, d, s, a, b, kept)
	s.caret, s.anchor = a + len(kept), a
	return true
}

// ---------------------------------------------------------------- geometry

@(private)
input_line_height :: proc(t: ^Tree, size: f32, family: Family_Id = 0) -> f32 {
	if te := t.text; te != nil && te.ok do return text_line_height(te, size, family = family)
	return size * 1.25
}

// input_caret_x is the x of the caret at display offset `db`, relative to
// the start of the (unscrolled) text: the pen position before the first glyph
// of that cluster, or the full width at the end — read off the same laid-out
// line render_text draws, so the caret sits exactly between the glyphs.
//
// runa's per-glyph `cluster` is the source byte offset, except that a GSUB
// ligation (e.g. ccmp composing e + U+0301) leaves the glyphs after it with
// stale offsets (shape.odin re-syncs by truncation). Clusters are therefore
// trusted only when the line is provably 1:1 with the codepoints and
// non-decreasing; otherwise the prefix is measured through the same engine
// and shape cache, which can differ from the drawn pen only by a kerning
// pair across the caret.
@(private)
input_caret_x :: proc(t: ^Tree, s: ^Text_Input_State, db: int) -> f32 {
	off := clamp(db, 0, len(s.display))
	te := t.text
	if te == nil || !te.ok {
		return f32(utf8.rune_count_in_string(s.display[:off])) * s.size * 0.5
	}
	lines := text_lines(te, s.display, s.size, 0, s.weight, family = s.family, tabular = s.tabular)
	if len(lines) == 0 do return 0
	glyphs := lines[0].glyphs
	if line_has_rtl(glyphs) do return line_caret_x(glyphs, off)
	if line_clusters_valid(s.display, glyphs) {
		pen: f32
		for g in glyphs {
			if int(g.cluster) >= off do return pen
			pen += g.x_advance
		}
		return pen
	}
	if off == len(s.display) {
		w: f32
		for g in glyphs do w += g.x_advance
		return w
	}
	return prefix_width(te, s.display[:off], s.size, weight = s.weight, family = s.family, tabular = s.tabular)
}

// line_clusters_valid says whether a line's glyph clusters can be read as
// byte offsets: one glyph per codepoint and never going backwards.
@(private)
line_clusters_valid :: proc(s: string, glyphs: []runa.Paragraph_Glyph) -> bool {
	if len(glyphs) != utf8.rune_count_in_string(s) do return false
	prev := -1
	for g in glyphs {
		c := int(g.cluster)
		if c < prev || c >= len(s) do return false
		prev = c
	}
	return true
}

// prefix_width lays out `prefix` on its own (through the engine's shape
// cache, scratch in the temp allocator) and returns its advance width.
@(private)
prefix_width :: proc(te: ^Text_Engine, prefix: string, size: f32, mono := false, tab: u8 = 0, weight := Font_Weight.Regular, italic := false, no_liga := false, family: Family_Id = 0, tabular := false) -> (w: f32) {
	if len(prefix) == 0 || !text_size_ok(size) do return 0
	lines, err := text_layout(te, prefix, text_opts(te, size, 0, weight = weight, mono = mono, italic = italic, no_liga = no_liga, family = family, tabular = tabular), context.temp_allocator)
	if err != .None || len(lines) == 0 do return 0
	control_advances(te, prefix, lines, size, mono, tab) // as text_lines: tabs to their stops, controls take no room
	for g in lines[0].glyphs do w += g.x_advance
	for &l in lines do runa.line_destroy(&l, context.temp_allocator)
	delete(lines, context.temp_allocator)
	return
}

// input_hit returns the display offset of the grapheme boundary nearest to
// `x` (relative to the unscrolled text start): a binary search over the
// boundaries with input_caret_x as the (monotone, for LTR text) oracle.
@(private)
input_hit :: proc(t: ^Tree, s: ^Text_Input_State, x: f32) -> int {
	bounds := make([dynamic]int, 0, len(s.display) / 2 + 2, context.temp_allocator)
	append(&bounds, 0)
	it := runa.grapheme_iter_make(s.display)
	for {
		_, hi, ok := runa.grapheme_iter_next(&it)
		if !ok do break
		append(&bounds, hi)
	}
	if glyphs := input_glyphs(t, s); line_has_rtl(glyphs) {
		// the caret moves both ways along a line that mixes directions: the nearest boundary, not a search
		best, best_d := 0, max(f32)
		for b in bounds {
			if d := abs(line_caret_x(glyphs, b) - x); d < best_d do best, best_d = b, d
		}
		return best
	}
	lo, hi := 0, len(bounds) - 1
	for lo < hi {
		mid := (lo + hi + 1) / 2
		if input_caret_x(t, s, bounds[mid]) <= x { lo = mid } else { hi = mid - 1 }
	}
	if lo + 1 < len(bounds) {
		left := x - input_caret_x(t, s, bounds[lo])
		right := input_caret_x(t, s, bounds[lo + 1]) - x
		if right < left do lo += 1
	}
	return bounds[lo]
}

// input_glyphs is the field's shaped line, nil without a text engine.
@(private)
input_glyphs :: proc(t: ^Tree, s: ^Text_Input_State) -> []runa.Paragraph_Glyph {
	te := t.text
	if te == nil || !te.ok || len(s.display) == 0 do return nil
	lines := text_lines(te, s.display, s.size, 0, s.weight, family = s.family, tabular = s.tabular)
	return lines[0].glyphs if len(lines) > 0 else nil
}

// input_inner is the text area: the node's rect minus padding.
@(private)
input_inner :: proc(d: ^Node_Data) -> Rect {
	p := d.layout.padding
	return {d.abs.x + p[3], d.abs.y + p[0], max(d.abs.w - p[1] - p[3], 0), max(d.abs.h - p[0] - p[2], 0)}
}

// layout_text_input measures a field: one line of body text plus padding,
// TEXT_INPUT_DEFAULT_WIDTH wide unless the constraints say otherwise.
@(private)
layout_text_input :: proc(t: ^Tree, n: Node, d: ^Node_Data, cc: Constraints) -> [2]f32 {
	s, ok := t.inputs[n]
	size := s.size if ok && s.size > 0 else field_look(&t.theme).text_size
	p := d.layout.padding
	return constrain(cc, {TEXT_INPUT_DEFAULT_WIDTH, input_line_height(t, size, s.family) + p[0] + p[2]})
}

// ---------------------------------------------------------------- paint

// paint_text_input emits a field's border, selection, text (or placeholder),
// and caret after emit_node has drawn its background and focus ring. The
// horizontal scroll is settled here, where the laid-out width is known.
@(private)
paint_text_input :: proc(t: ^Tree, n: Node, d: ^Node_Data, l: ^Layer) {
	s, ok := &t.inputs[n]
	if !ok do return
	th := &t.theme
	lk := field_look(th)
	focused := .Focused in d.flags
	disabled := .Disabled in d.flags
	alpha: f32 = th.state.disabled_alpha if disabled else 1
	alpha *= t.paint_opacity // the field fades with its dialog

	if !s.quiet { // a quiet field is inside something that draws the chrome: a search_field's frame
		on := focused && !disabled
		border := lk.focus_border if on else lk.border
		if .Invalid in d.access.states do border = th.color.danger // set_invalid
		border.a *= alpha
		append(&l.cmds, Draw_Rect{rect = d.abs, radius = d.style.radius, border_w = lk.focus_border_width if on else lk.border_width, border = border})
	}

	inner := input_inner(d)
	if s.caps && focused && !disabled { // Caps Lock on in a password: its sign at the end, the text stopping short of it
		sz := s.size
		gap := th.space[.xs]
		inner.w = max(inner.w - sz - gap, 0)
		c := ensure_contrast(th.color.warning, d.style.bg, 3) // a sign that means something: 3:1, as any graphic
		c.a *= alpha
		append(&l.cmds, Draw_Icon{pos = {inner.x + inner.w + gap, d.abs.y + (d.abs.h - sz) / 2}, icon = .Arrow_Big_Up_Dash, size = sz, color = c})
	}
	lh := input_line_height(t, s.size, s.family)
	text_y := inner.y + max((inner.h - lh) / 2, 0)
	src := input_src(s)
	dc := input_display_off(s, src, s.caret)
	da := input_display_off(s, src, s.anchor)
	caret_x := input_caret_x(t, s, input_caret_display(s, src))
	glyphs := input_glyphs(t, s)
	bidi := line_has_rtl(glyphs)
	text_w := input_caret_x(t, s, len(s.display))
	if bidi { // the caret after the last character is not the line's right end
		text_w = 0
		for g in glyphs do text_w += g.x_advance
	}

	// Scroll: never past the end, and (while focused) the caret stays inside,
	// with room for its own width.
	s.scroll_x = clamp(s.scroll_x, 0, max(text_w + lk.caret_width - inner.w, 0))
	if focused {
		if caret_x - s.scroll_x > inner.w - lk.caret_width do s.scroll_x = caret_x - inner.w + lk.caret_width
		if caret_x - s.scroll_x < 0 do s.scroll_x = caret_x
	}
	x0 := inner.x - s.scroll_x

	// Clip to the text area horizontally, the whole field vertically (accents
	// and emoji overshoot the line box).
	append(&l.cmds, Draw_Clip_Push{{inner.x, d.abs.y, inner.w, d.abs.h}})
	from := len(l.cmds)
	if len(s.display) > 0 {
		fg := lk.ink
		fg.a *= alpha
		append(&l.cmds, Draw_Text{pos = {x0, text_y}, str = s.display, size = s.size, color = fg, weight = s.weight, family = s.family, tabular = s.tabular})
	} else if len(s.placeholder) > 0 {
		fg := lk.placeholder
		fg.a *= alpha
		append(&l.cmds, Draw_Text{pos = {inner.x, text_y}, str = s.placeholder, size = s.size, color = fg, weight = s.weight, family = s.family})
	}
	// The selection over the words, in a band that can be seen and with the
	// selected ones redrawn to read on it (selection_paint.odin). A field
	// with a fill of its own is checked against it; one without sits on a
	// theme surface, which the theme's pair always stands off.
	if focused && dc != da {
		band, text := selection_pair(th)
		if d.style.bg.a > 0 do band, text = selection_pair(th, d.style.bg, lk.ink)
		if bidi {
			rects := make([dynamic]Rect, context.temp_allocator)
			for r in line_ranges(glyphs, min(dc, da), max(dc, da)) do append(&rects, Rect{x0 + r[0], text_y, r[1] - r[0], lh})
			selection_overpaint(t, l, from, len(l.cmds), rects[:], band, text)
		} else {
			xa := input_caret_x(t, s, min(dc, da))
			xb := input_caret_x(t, s, max(dc, da))
			sel_rect := [1]Rect{{x0 + xa, text_y, xb - xa, lh}}
			selection_overpaint(t, l, from, len(l.cmds), sel_rect[:], band, text)
		}
	}
	if len(s.pre) > 0 { // the composition is underlined, its own cursor range more strongly
		pre_start := input_display_off(s, src, s.pre_at)
		xa := input_caret_x(t, s, pre_start)
		xb := input_caret_x(t, s, pre_start + len(s.pre))
		line := lk.ink
		line.a *= alpha
		append(&l.cmds, Draw_Rect{rect = {x0 + xa, text_y + lh - 2, xb - xa, 1}, color = line})
		if s.pre_lo >= 0 && s.pre_hi > s.pre_lo {
			ha := input_caret_x(t, s, pre_start + clamp(s.pre_lo, 0, len(s.pre)))
			hb := input_caret_x(t, s, pre_start + clamp(s.pre_hi, 0, len(s.pre)))
			append(&l.cmds, Draw_Rect{rect = {x0 + ha, text_y + lh - 3, hb - ha, 2}, color = line})
		}
	}
	if focused && !disabled {
		if !s.was_focused do s.blink_start = t.now_ms
		r := Rect{x0 + caret_x, text_y, lk.caret_width, lh}
		if caret_shown(t, n, &s.blink_start) {
			caret := lk.caret
			caret.a *= t.paint_opacity
			append(&l.cmds, Draw_Rect{rect = r, color = caret})
		}
		caret_painted(t, r)
	}
	s.was_focused = focused && !disabled
	append(&l.cmds, Draw_Clip_Pop{})
}

// text_input_wake repaints the focused field's or editor's caret. The
// tree's timers already do this when a blink is due, so an app has no need
// to call it.
text_input_wake :: proc(t: ^Tree) {
	if d := node_get(t, t.focus); d != nil {
		if _, ok := d.kind.(Text_Input_Kind); ok do mark_blink_dirty(t, t.focus)
		if _, ok := t.areas[t.focus]; ok do mark_blink_dirty(t, t.focus)
	}
}

// ---------------------------------------------------------------- editing

// focused_input returns the focused, enabled field, or ok = false.
@(private)
focused_input :: proc(t: ^Tree) -> (n: Node, d: ^Node_Data, s: ^Text_Input_State, ok: bool) {
	n = t.focus
	d = node_get(t, n)
	if d == nil || .Disabled in d.flags do return
	if _, is_input := d.kind.(Text_Input_Kind); !is_input do return
	s, ok = &t.inputs[n]
	if ok do input_fit(s)
	return
}

// input_fit keeps a field's caret and selection inside its buffer. A buffer
// shared with another field — a form's value on two surfaces — may have
// changed since this field was last built, which is when they were last
// fitted to it; everything that uses them on a key or an input method's word
// fits them first.
@(private)
input_fit :: proc(s: ^Text_Input_State) {
	src := input_src(s)
	s.caret = grapheme_snap(src, clamp(s.caret, 0, len(src)))
	s.anchor = grapheme_snap(src, clamp(s.anchor, 0, len(src)))
}

@(private)
input_fire :: proc(ui: ^Ui($Msg), n: Node, h: Handler(Msg, string), value: string) {
	switch v in h {
	case Msg:
		append(&ui.msgs, v)
	case proc(Ev(string)) -> Msg:
		d := node_get(&ui.tree, n)
		append(&ui.msgs, v(Ev(string){value = value, tag = d.tag if d != nil else 0, node = n}))
	}
}

// input_replace replaces buffer bytes [lo, hi) with `ins`, puts the caret
// after it, and queues on_change.
@(private)
input_replace :: proc(ui: ^Ui($Msg), n: Node, d: ^Node_Data, s: ^Text_Input_State, lo, hi: int, ins: string, own_step := false) {
	if s.value == nil do return
	a, b := min(lo, hi), max(lo, hi)
	// Every edit comes through here, so this is the one place the journal
	// is kept.
	input_undo_record(&ui.tree, s, a, b, ins, own_step)
	ins := ins
	// `max_length` counts characters, not bytes, and truncates on a grapheme
	// boundary so a capped paste never ends in a broken cluster.
	if s.max_length > 0 && len(ins) > 0 {
		have := utf8.rune_count_in_string(str(s.value^))
		removed := utf8.rune_count_in_string(str(s.value^)[a:b])
		room := s.max_length - (have - removed)
		if room <= 0 do return
		if utf8.rune_count_in_string(ins) > room do ins = ins[:grapheme_snap(ins, len(rune_prefix(ins, room)))]
	}
	text_delete(s.value, a, b)
	s.caret = text_insert(s.value, a, ins)
	s.anchor = s.caret
	t := &ui.tree
	input_refresh(t, n, d, s)
	input_touch(t, n, s)
	if h, ok := ui.input_handlers[n]; ok do input_fire(ui, n, h.on_change, str(s.value^))
}

@(private)
input_move :: proc(t: ^Tree, n: Node, s: ^Text_Input_State, to: int, extend: bool) {
	s.caret = to
	if !extend do s.anchor = to
	input_touch(t, n, s)
}

@(private)
input_copy :: proc(t: ^Tree, s: ^Text_Input_State) -> bool {
	lo, hi := min(s.caret, s.anchor), max(s.caret, s.anchor)
	if lo == hi || t.clipboard.set == nil || s.password do return false // a passphrase never goes to the clipboard (nor is cut)
	return t.clipboard.set(t.clipboard.user, input_src(s)[lo:hi])
}

// text_event commits typed text (platform Ev_Text) into the focused field:
// it replaces the selection, or inserts at the caret. Control characters are
// dropped. Returns true when anything changed.
text_event :: proc(ui: ^Ui($Msg), text: string) -> bool {
	n, d, s, ok := focused_input(&ui.tree)
	if !ok do return false
	clean := sanitize_input(text)
	if len(clean) == 0 do return false
	input_replace(ui, n, d, s, s.anchor, s.caret, clean)
	return true
}

// text_input_key handles a key press for the focused field. Returns true if
// the key was consumed; Tab (and anything the field does not use) falls
// through to key_event.
text_input_key :: proc(ui: ^Ui($Msg), key: Key, mods: Mods) -> bool {
	t := &ui.tree
	n, d, s, ok := focused_input(t)
	if !ok do return false
	if shift_chord_bound(ui, key, mods) do return false // the app's own Ctrl+Shift+C / V / A wins
	src := input_src(s)
	shift, ctrl := .Shift in mods, .Ctrl in mods
	lo, hi := min(s.caret, s.anchor), max(s.caret, s.anchor)
	has_sel := lo != hi
	if inline_key(ui, n, key, mods) do return true // an editor standing in for a label: Enter / Escape / Tab
	if h, has := ui.input_handlers[n]; has && handler_live(h.on_key) && key_offered(ui, key, mods) {
		handler_send(ui, h.on_key, Key_Press{key, mods}, n) // a list below the field: walked, its current row pinned or removed
		return true
	}
	#partial switch key {
	case .Left:
		to: int
		switch {
		case ctrl:              to = word_prev(src, s.caret)
		case has_sel && !shift: to = lo
		case:                   to = grapheme_prev(src, s.caret)
		}
		input_move(t, n, s, to, shift)
	case .Right:
		to: int
		switch {
		case ctrl:              to = word_next(src, s.caret)
		case has_sel && !shift: to = hi
		case:                   to = grapheme_next(src, s.caret)
		}
		input_move(t, n, s, to, shift)
	case .Home:
		input_move(t, n, s, 0, shift)
	case .End:
		input_move(t, n, s, len(src), shift)
	case .Backspace:
		if has_sel {
			input_replace(ui, n, d, s, lo, hi, "")
		} else if s.caret > 0 {
			from := word_prev(src, s.caret) if ctrl else grapheme_prev(src, s.caret)
			input_replace(ui, n, d, s, from, s.caret, "")
		}
	case .Delete:
		if has_sel {
			input_replace(ui, n, d, s, lo, hi, "")
		} else if s.caret < len(src) {
			to := word_next(src, s.caret) if ctrl else grapheme_next(src, s.caret)
			input_replace(ui, n, d, s, s.caret, to, "")
		}
	case .A:
		if ctrl {
			s.anchor = 0
			s.caret = len(src)
			input_touch(t, n, s)
		}
	case .C:
		if ctrl do input_copy(t, s)
	case .X:
		if ctrl && input_copy(t, s) do input_replace(ui, n, d, s, lo, hi, "")
	case .Z:
		// Ctrl+Z undoes; both Ctrl+Shift+Z and Ctrl+Y redo, since people
		// arrive with either habit.
		if !ctrl do return false
		if .Shift in mods do return input_undo_apply(ui, n, d, s, &s.redo, &s.undo)
		return input_undo_apply(ui, n, d, s, &s.undo, &s.redo)
	case .Y:
		if !ctrl do return false
		return input_undo_apply(ui, n, d, s, &s.redo, &s.undo)
	case .V:
		// A field that prefers pictures takes the picture over the text a
		// browser puts beside it, and inserts nothing.
		if ctrl && s.paste_prefer == .Picture && paste_other_send(ui, n, picture_only = true) do return true
		if ctrl && t.clipboard.get != nil {
			empty := true
			if pasted, got := t.clipboard.get(t.clipboard.user, context.temp_allocator); got {
				clean := sanitize_input(pasted)
				if len(clean) > 0 { input_replace(ui, n, d, s, lo, hi, clean); empty = false }
				if s.password { // the pasted passphrase's scratch copies
					if raw_data(clean) != raw_data(pasted) do mem.zero(raw_data(clean), len(clean))
					mem.zero(raw_data(pasted), len(pasted))
				}
			}
			if empty do return paste_other_send(ui, n) // a picture or files: the app's to take
		}
	case .Enter:
		h, has := ui.input_handlers[n]
		// A modified Enter the window bound is the window's, with or without
		// `on_key` (a file manager's Alt+Enter from its path field). A plain
		// Enter is always the field's, and so is a modified one nothing bound:
		// a dialog's field must submit however sloppily Enter was pressed.
		if mods & {.Shift, .Ctrl, .Alt, .Super} != {} && shortcut_bound(ui, key, mods) do return false
		// `handler_live`, not `== nil`: an on_submit passed through a ternary
		// holds a nil proc, and claiming Enter for it would starve the
		// dialog's default button.
		if !has || !handler_live(h.on_submit) do return false // not this field's key: a dialog's default button may take it
		input_fire(ui, n, h.on_submit, src)
	case .Escape:
		// A search field's Escape clears it and stops there, but only while
		// there is something to clear: an empty one lets Escape go on to
		// close whatever holds it.
		if s.search && len(input_src(s)) > 0 {
			input_replace(ui, n, d, s, 0, len(input_src(s)), "")
			if h, has := ui.input_handlers[n]; has do input_fire(ui, n, h.on_change, src)
			return true
		}
		if h, has := ui.input_handlers[n]; has {
			if m, cancels := h.on_cancel.?; cancels {
				append(&ui.msgs, m)
				return true
			}
		}
		// A selection the person made is cleared first, and Escape stops
		// there; the one `focus` made is not theirs, so Escape goes on (to
		// close the bar that focused the field).
		if !has_sel || s.focus_sel do return false
		s.anchor = s.caret
		input_touch(t, n, s)
	case .Space:
		// The character arrives through text_event; swallow the key so it
		// does not activate anything else.
	case .Up, .Down, .Page_Up, .Page_Down, .Tab, .Unknown, .F, .G, .H, .Slash, .F3, .B, .I, .U, .E, .K, .Menu, .F10,
		.D, .J, .L, .M, .N, .O, .P, .Q, .R, .S, .T, .W, .N0, .N1, .N2, .N3, .N4, .N5, .N6, .N7, .N8, .N9, .F1, .F2, .F4, .F5, .F6, .F7, .F8, .F9, .F11, .F12, .Insert, .Minus, .Equal, .Comma, .Period, .Grave, .Bracket_L, .Bracket_R, .Backslash, .Semicolon, .Apostrophe:
		return false
	}
	return true
}

// key_offered says whether a field with `on_key` passes `key` on to it:
// Up, Down, Page Up and Page Down, unless Alt or Super makes them the
// window's; Shift+Delete, never the window's (a file manager's Shift+Delete
// must not fire from a field); Enter with Shift, Ctrl or Alt, a plain one
// staying `on_submit`'s; and Ctrl or Alt, not both (that is AltGr typing on
// Windows), with a character key other than the field's Ctrl+A, C, X, V, Z
// and Y. A Ctrl or Alt chord the window binds with `shortcut` stays the
// window's.
@(private)
key_offered :: proc(ui: ^Ui($Msg), key: Key, mods: Mods) -> bool {
	SHIFT :: Mods{.Shift}
	CTRL :: Mods{.Ctrl}
	ALT :: Mods{.Alt}
	// with Ctrl: select all, copy, cut, paste, undo, redo. (A predicate, not
	// a set: the Key enum is past what a bit_set holds.)
	field_key :: proc "contextless" (k: Key) -> bool {
		#partial switch k {
		case .A, .C, .X, .V, .Z, .Y: return true
		}
		return false
	}
	#partial switch key {
	case .Delete:
		return mods == SHIFT
	case .Enter:
		// A modified Enter goes to `on_key` with its mods, since `on_submit`'s
		// `Ev(string)` has none (a find bar's Shift+Enter is the previous
		// match). A plain Enter stays `on_submit`'s; a chord the window bound
		// stays the window's.
		if mods & (SHIFT | CTRL | ALT) == {} || .Super in mods do return false
		return !shortcut_bound(ui, key, mods)
	case .Up, .Down, .Page_Up, .Page_Down:
		if window_nav(key, mods) do return false
		return .Ctrl not_in mods || !shortcut_bound(ui, key, mods)
	case .Space:
		return false
	}
	if !key_prints(key) || .Super in mods do return false
	chord := mods & (CTRL | ALT)
	if chord != CTRL && chord != ALT do return false
	if chord == CTRL && field_key(key) do return false
	return !shortcut_bound(ui, key, mods)
}

// ---------------------------------------------------------------- pointer

// input_at returns the field under `pos`, if that is what the pointer would
// interact with.
@(private)
input_at :: proc(ui: ^Ui($Msg), pos: [2]f32) -> (n: Node, d: ^Node_Data, s: ^Text_Input_State, ok: bool) {
	t := &ui.tree
	n = interactive_target(ui, hit_test(t, pos))
	d = node_get(t, n)
	if d == nil do return
	if _, is_input := d.kind.(Text_Input_Kind); !is_input do return
	s, ok = &t.inputs[n]
	return
}

// input_hit_src maps a pointer x to a buffer offset on a grapheme boundary.
@(private)
input_hit_src :: proc(t: ^Tree, d: ^Node_Data, s: ^Text_Input_State, px: f32) -> int {
	inner := input_inner(d)
	db := input_hit(t, s, px - inner.x + s.scroll_x)
	return input_src_off(s, input_src(s), db)
}

// text_input_pointer_button handles a left press or release for fields: a
// press focuses the field and places the caret (double-click selects the
// word, triple-click everything), a release ends a drag.
// Returns true when the event belonged to a field.
text_input_pointer_button :: proc(ui: ^Ui($Msg), pressed: bool, pos: [2]f32) -> bool {
	t := &ui.tree
	if !pressed {
		for _, &s in t.inputs {
			if s.dragging {
				s.dragging = false
				return true
			}
		}
		return false
	}
	n, d, s, ok := input_at(ui, pos)
	if !ok do return false
	set_focus(t, n, false) // pointer focus never shows the ring
	// The click's own time, not the frame clock, so a busy app does not need
	// a faster double-click than an idle one.
	click_ms := ui.pointer.time_ms
	if click_ms >= s.last_click_ms && click_ms - s.last_click_ms <= MULTI_CLICK_MS && abs(pos.x - s.last_click_pos.x) <= MULTI_CLICK_PX && abs(pos.y - s.last_click_pos.y) <= MULTI_CLICK_PX {
		s.clicks += 1
	} else {
		s.clicks = 1
	}
	s.last_click_ms, s.last_click_pos = click_ms, pos
	src := input_src(s)
	b := input_hit_src(t, d, s, pos.x)
	switch s.clicks {
	case 1:
		s.caret, s.anchor = b, b
		s.dragging = true
	case 2:
		s.anchor, s.caret = word_at(src, b)
	case:
		s.anchor, s.caret = 0, len(src)
	}
	input_touch(t, n, s)
	primary_mark(t, n, fresh = true)
	return true
}

// text_input_pointer_move extends the selection while a press drags inside a
// field. Returns true while a drag is in progress.
text_input_pointer_move :: proc(ui: ^Ui($Msg), pos: [2]f32) -> bool {
	t := &ui.tree
	for n, &s in t.inputs {
		if !s.dragging do continue
		d := node_get(t, n)
		if d == nil {
			s.dragging = false
			continue
		}
		if b := input_hit_src(t, d, &s, pos.x); b != s.caret {
			s.caret = b
			input_touch(t, n, &s)
			primary_mark(t, n)
		}
		return true
	}
	return false
}

// input_context_press handles a right-click in a field that was given
// `on_context`, as an editor does: the caret moves to the pointer unless
// that is inside the selection, which is kept for the menu's Cut and Copy.
// It carries the editor's `Editor_Context`, so one menu serves both; a
// field has no blocks, so the position's block is always 0.
@(private)
input_context_press :: proc(ui: ^Ui($Msg), pos: [2]f32) -> bool {
	n, d, s, ok := input_at(ui, pos)
	if !ok do return false
	h, has := ui.editor_contexts[n]
	if !has do return false
	t := &ui.tree
	set_focus(t, n, false)
	at := input_hit_src(t, d, s, pos.x)
	lo, hi := min(s.anchor, s.caret), max(s.anchor, s.caret)
	inside := hi > lo && at >= lo && at <= hi
	if !inside do input_move(t, n, s, at, extend = false)
	ui.context_pos = pos
	return handler_send(ui, h, Editor_Context{pos = {0, at}, in_selection = inside, at = pos}, n)
}

// ------------------------------------------------------------ undo

// Input_Step is what a field held before one undoable step.
@(private)
Input_Step :: struct {
	text:   string, // owned, tree allocator
	caret:  int,
	anchor: int,
}

// How many steps a field remembers. A single-line field holds a URL or a
// name, so this is a few kilobytes at worst and far more history than
// anyone reaches for.
@(private) INPUT_UNDO_MAX :: 64
// Typing pauses longer than this start a new step, as every editor does.
@(private) INPUT_UNDO_PAUSE_MS :: f64(700)

// input_undo_record notes what the field held before an edit, coalescing a
// run of typed characters into one step so Ctrl+Z takes back a word rather
// than a letter. A password field keeps no journal: a history of a secret
// is a copy of it, kept for as long as the field lives.
@(private)
input_undo_record :: proc(t: ^Tree, s: ^Text_Input_State, lo, hi: int, ins: string, own_step := false) {
	if s.password || s.value == nil do return
	// `own_step`: an app's insert (a keypad key) is one deliberate act that
	// neither joins typing before it nor swallows typing after it; without
	// the flag a one-character insert looks exactly like a typed key.
	typed := !own_step && lo == hi && len(ins) > 0 && len(ins) <= 4 && ins != " " // one character, and not the space that ends a word
	now := t.now_ms
	coalesce := typed && s.undo_open && len(s.undo) > 0 && now - s.undo_at_ms <= INPUT_UNDO_PAUSE_MS
	s.undo_at_ms = now
	s.undo_open = typed
	if coalesce do return // the open step already holds what it was before the run

	input_steps_clear(t, &s.redo) // a new edit is a new future
	if s.undo == nil do s.undo = make([dynamic]Input_Step, t.allocator)
	append(&s.undo, Input_Step{
		text   = strings.clone(str(s.value^), t.allocator),
		caret  = s.caret,
		anchor = s.anchor,
	})
	if len(s.undo) > INPUT_UNDO_MAX {
		delete(s.undo[0].text, t.allocator)
		ordered_remove(&s.undo, 0)
	}
}

@(private)
input_steps_clear :: proc(t: ^Tree, steps: ^[dynamic]Input_Step) {
	for st in steps do delete(st.text, t.allocator)
	clear(steps)
}

// input_undo_apply moves one step between the two journals, putting the
// field back to what the step remembers.
@(private)
input_undo_apply :: proc(ui: ^Ui($Msg), n: Node, d: ^Node_Data, s: ^Text_Input_State, from, to: ^[dynamic]Input_Step) -> bool {
	if s.password || s.value == nil || len(from) == 0 do return false
	t := &ui.tree
	step := pop(from)
	if to^ == nil do to^ = make([dynamic]Input_Step, t.allocator)
	append(to, Input_Step{
		text   = strings.clone(str(s.value^), t.allocator),
		caret  = s.caret,
		anchor = s.anchor,
	})
	text_set(s.value, step.text)
	s.caret = clamp(step.caret, 0, len(str(s.value^)))
	s.anchor = clamp(step.anchor, 0, len(str(s.value^)))
	delete(step.text, t.allocator)
	s.undo_open = false
	input_refresh(t, n, d, s)
	input_touch(t, n, s)
	if h, ok := ui.input_handlers[n]; ok do input_fire(ui, n, h.on_change, str(s.value^))
	return true
}

// input_undo_destroy frees a field's journals.
@(private)
input_undo_destroy :: proc(t: ^Tree, s: ^Text_Input_State) {
	input_steps_clear(t, &s.undo)
	input_steps_clear(t, &s.redo)
	delete(s.undo)
	delete(s.redo)
	s.undo, s.redo = nil, nil
}
