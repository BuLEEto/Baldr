package baldr

// Editing in place: a label becomes a text field where it stands. A table
// cell (`cell_edit`), an icon view tile and a tree item (`on_submit` on
// their builders) all do it the same way — the field takes focus with
// the name selected up to its extension, Enter or leaving the field
// commits, Escape reverts, Tab commits and asks for the next cell. The
// views ask the app to start one through `on_edit` (F2, or a slow second
// click on the selected item — a double-click activates instead), so the
// app decides which cells may change and what a commit does.

import "base:runtime"
import "core:strings"

// Cell_Ref names a table cell: the row's data index and the column's index.
Cell_Ref :: struct {
	row, col: int,
}

// Edit_Ref is where an editor stands, for Tab to find the next cell.
@(private)
Edit_Ref :: struct {
	view:     Node, // the table, icon view or tree; NONE elsewhere
	row, col: int,
}

@(private)
Edit_Handlers :: struct($Msg: typeid) {
	on_submit: Handler(Msg, string),
	on_cancel: Maybe(Msg),
	ref:       Edit_Ref,
	done:      bool, // committed or cancelled: nothing fires again until the app rebuilds without it
}

// Edit_Pending is a slow second click on a selected item being timed:
// it asks for an edit unless a second click makes it a double.
@(private)
Edit_Pending :: struct {
	view:  Node,
	index: int, // the row / tile index, or a tree item's tag
	col:   int,
	at:    f64,
}

// inline_edit_over builds the editor standing in for `value` over `anchor`
// rather than inside it: an overlay card `width` wide, its top at the
// anchor's plus `nudge`, holding a wrapping editor so a name longer than the
// label's room shows whole instead of scrolling with the caret. The card is
// opaque and shadowed because it covers the tiles around it; `.Over`
// placement also keeps it out of a layer surface's popup surfaces
// (popup_candidate), since it is the window's own content. Enter, Escape and
// Tab work as in the one-line editor, through the same `ui.edits` entry.
@(private)
inline_edit_over :: proc(ui: ^Ui($Msg), value: string, on_submit: Handler(Msg, string), on_cancel: Maybe(Msg), select_stem: bool,
	ref: Edit_Ref, label: string, anchor: Node, within: Node, width: f32, nudge: [2]f32, key: u64, loc: runtime.Source_Code_Location) -> Node {
	t := &ui.tree
	lk := field_look(&t.theme)
	k := (u64(anchor) * 0xD6E8_FEB8_6659_FD93) | key | 1
	card, _ := overlay_begin(ui, k, loc)
	cd := node_get(t, card)
	if cd == nil do return NODE_NONE
	cd.access.role = .Group
	cs := cd.style
	cs.bg = lk.inline_card.fill // opaque: the names it covers must not read through it
	cs.radius = lk.inline_card.radius
	cs.border_w = lk.inline_card.border_width
	cs.border = lk.inline_card.border
	cs.shadow = lk.inline_card.shadow
	cs.material = {} // never glass: it is over the app's own tiles, not the desktop
	set_style(t, card, cs)
	set_layout(t, card, Layout_Props{axis = .Column, align = .Stretch, width = width, padding = lk.inline_card.padding})
	t.overlay_rules[card] = {anchor = anchor, placement = .Over, align = .Center, nudge = nudge, within = within}

	// The document is the toolkit's: the app passed a string, and this
	// editor holds it until the edit is committed or cancelled. Heap, not
	// the map's own memory, because the editor keeps the pointer.
	doc := ui.edit_docs[card]
	if doc == nil {
		doc = new(Document, t.allocator)
		doc^ = document_make(value, t.allocator)
		ui.edit_docs[card] = doc
	}
	n := text_area(ui, doc, label = label, key = 1, loc = loc)
	editor_options(ui, n, wrap = true, min_lines = 1, max_lines = INLINE_EDIT_LINES, frame = false,
		size = lk.inline_card.text_size)
	prior, existed := ui.edits[n]
	if !existed {
		// first build: focus, with the name selected up to its extension
		set_focus(t, n, true)
		if as := &t.areas[n]; as != nil {
			line := block_str(doc, 0)
			as.anchor = Pos{0, 0}
			as.caret = Pos{0, stem_end(line) if select_stem else len(line)}
			area_touch(t, n, as)
		}
	}
	node_get(t, n).tag = u64(ref.row)
	ui.edits[n] = Edit_Handlers(Msg){on_submit = on_submit, on_cancel = on_cancel, ref = ref, done = prior.done if existed else false}
	end(ui) // the card's scope, and the overlay redirect with it
	return n
}

// INLINE_EDIT_LINES is as tall as an editor over a label grows before it
// scrolls inside itself; a name needing more than this is pathological.
INLINE_EDIT_LINES :: 8

// inline_doc_free destroys a document the toolkit made for a wrapping
// editor and frees it.
@(private)
inline_doc_free :: proc(t: ^Tree, doc: ^Document) {
	if doc == nil do return
	document_destroy(doc)
	free(doc, t.allocator)
}

// inline_one_line is the editor's text as a name: a name has no newlines,
// so a paste that brought some reads as spaces rather than as a name the
// app cannot use.
@(private)
inline_one_line :: proc(doc: ^Document, allocator := context.temp_allocator) -> string {
	text := document_text(doc, allocator)
	if !strings.contains_rune(text, '\n') do return text
	parts := strings.split(text, "\n", context.temp_allocator)
	for &p in parts do p = strings.trim_space(p)
	return strings.join(parts, " ", allocator)
}

// inline_edit builds the editor standing in for `value`.
@(private)
inline_edit :: proc(ui: ^Ui($Msg), value: string, on_submit: Handler(Msg, string), on_cancel: Maybe(Msg), select_stem: bool,
	ref: Edit_Ref, label: string, key: u64, loc: runtime.Source_Code_Location) -> Node {
	t := &ui.tree
	n := text_input(ui, nil, initial = value, compact = true, label = label, key = key, loc = loc)
	prior, existed := ui.edits[n]
	if !existed {
		// first build: focus, with the name selected up to its extension
		set_focus(t, n, true)
		if s := text_input_state(t, n); s != nil {
			src := input_src(s)
			s.anchor = 0
			s.caret = stem_end(src) if select_stem else len(src)
			input_touch(t, n, s)
		}
	}
	node_get(t, n).tag = u64(ref.row)
	ui.edits[n] = Edit_Handlers(Msg){on_submit = on_submit, on_cancel = on_cancel, ref = ref, done = prior.done if existed else false}
	return n
}

// stem_end is where a file name's extension begins (its length when it
// has none, or is only an extension like ".bashrc").
@(private)
stem_end :: proc(name: string) -> int {
	for i := len(name) - 1; i > 0; i -= 1 {
		if name[i] == '.' do return i
		if name[i] == '/' do break
	}
	return len(name)
}

// inline_key: Enter commits, Escape reverts, Tab commits and moves on.
// Called for a focused text field before its own keys.
@(private)
inline_key :: proc(ui: ^Ui($Msg), n: Node, key: Key, mods: Mods) -> bool {
	e, is_edit := &ui.edits[n]
	if !is_edit do return false
	#partial switch key {
	case .Enter:
		inline_submit(ui, n)
		return true
	case .Escape:
		inline_cancel(ui, n)
		return true
	case .Tab:
		ref := e.ref
		inline_submit(ui, n)
		if ref.view != NODE_NONE do edit_request_next(ui, ref, .Shift in mods)
		return true
	}
	return false
}

@(private)
inline_submit :: proc(ui: ^Ui($Msg), n: Node) {
	e := &ui.edits[n]
	if e == nil || e.done do return
	e.done = true
	t := &ui.tree
	if s := text_input_state(t, n); s != nil {
		input_fire(ui, n, e.on_submit, input_src(s))
		return
	}
	if as := &t.areas[n]; as != nil && as.doc != nil do input_fire(ui, n, e.on_submit, inline_one_line(as.doc)) // the wrapping one (inline_edit_over)
}

@(private)
inline_cancel :: proc(ui: ^Ui($Msg), n: Node) {
	e := &ui.edits[n]
	if e == nil || e.done do return
	e.done = true
	if m, has := e.on_cancel.?; has do append(&ui.msgs, m)
}

// edit_request_next asks for the cell after (or before) `ref`: the next
// column, then the first column of the next row.
@(private)
edit_request_next :: proc(ui: ^Ui($Msg), ref: Edit_Ref, back: bool) {
	t := &ui.tree
	h, has := ui.on_edit_cell[ref.view]
	ts, is_table := t.tables[ref.view]
	if !has || !is_table || len(ts.cols) == 0 do return
	row, col := ref.row, ref.col + (-1 if back else 1)
	if col >= len(ts.cols) { row, col = row + 1, 0 }
	if col < 0 { row, col = row - 1, len(ts.cols) - 1 }
	if row < 0 || row >= ts.count do return
	handler_send(ui, h, Cell_Ref{row, col}, ref.view)
}

// edit_pending_start times a slow second click on the selected item.
@(private)
edit_pending_start :: proc(ui: ^Ui($Msg), view: Node, index, col: int) {
	ui.edit_pending = {view = view, index = index, col = col, at = ui.tree.now_ms}
	tree_wake_at(&ui.tree, ui.tree.now_ms + TABLE_DOUBLE_CLICK_MS + 1, view)
}

// inline_tick: a field that lost focus commits; a timed slow click asks
// for its edit once a double-click can no longer follow.
@(private)
inline_tick :: proc(ui: ^Ui($Msg), now_ms: f64) {
	t := &ui.tree
	for n, &e in ui.edits {
		if e.done || !node_valid(t, n) || t.focus == n do continue
		inline_submit(ui, n)
	}
	p := ui.edit_pending
	if p.view == NODE_NONE do return
	if now_ms - p.at < TABLE_DOUBLE_CLICK_MS do return
	ui.edit_pending = {}
	if !node_valid(t, p.view) do return
	if h, has := ui.on_edit_cell[p.view]; has {
		handler_send(ui, h, Cell_Ref{p.index, p.col}, p.view)
	} else if h2, has2 := ui.on_edit[p.view]; has2 {
		handler_send(ui, h2, p.index, p.view)
	}
}

// cell_edit is a table cell holding an editor for `value` instead of its
// text: build it in place of `cell_text` for the cell the app is editing
// (after its `on_edit` asked). `on_submit` gets the new text (Ev.tag is
// the row); `on_cancel` is sent on Escape. `select_stem` selects up to
// the extension, as a rename wants; false selects it all.
//
//	if s.editing == (Cell_Ref{i, 0}) {
//		baldr.cell_edit(ui, name, proc(e: baldr.Ev(string)) -> Msg { return Renamed{int(e.tag), e.value} }, on_cancel = Msg(Edit_Done{}))
//	} else {
//		baldr.cell_text(ui, name, icon = .File)
//	}
cell_edit :: proc(ui: ^Ui($Msg), value: string, on_submit: Handler(Msg, string), on_cancel: Maybe(Msg) = nil,
	select_stem := true, loc := #caller_location) -> Node {
	t := &ui.tree
	row := ui.scopes[len(ui.scopes) - 1].node
	ref, in_row := ui.rows[row]
	col := 0
	if in_row do col = t.tables[ref.table].cell_i // the cell about to be built
	n := cell(ui, loc)
	inline_edit(ui, value, on_submit, on_cancel, select_stem, Edit_Ref{view = ref.table if in_row else NODE_NONE, row = ref.index if in_row else 0, col = col}, "Edit", 1, loc)
	close_scope(ui)
	return n
}
