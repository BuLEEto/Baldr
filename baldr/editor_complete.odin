package baldr

// Completion in an editor: a list under the caret, driven by the keys that
// drive every list in Baldr — Up / Down pick, Enter or Tab accept, Escape
// closes, a click accepts — and a List named "Completions" for assistive
// technology.
//
// Two ways in. A `code_editor` opens it on an identifier as it is typed (or
// on Ctrl+Space), which is what a completer for a language wants. Any
// editor can be given a **trigger** character instead: type it at the start
// of a word and the list opens on what follows, which is how a message box
// offers `@` mentions. The app supplies the candidates either way.

import "base:runtime"
import "core:strings"
import "core:unicode/utf8"

// Completion is one autocomplete candidate: `label` is shown, `insert`
// (or the label when empty) replaces what was typed, `detail` is a
// muted note (a type, a source, a folder and a date), `kind` colours the
// label in a code editor and is ignored anywhere else.
Completion :: struct {
	label, insert, detail: string,
	kind: Token_Kind,
}

// Completer supplies candidates for the `prefix` typed at `at` — the
// identifier before the caret, or what follows a trigger character
// (temp-allocated strings are fine: the editor copies what it keeps).
// `lang` is the code editor's language, nil in a plain editor. nil on a
// code editor means the built-in one: the language's words and the
// identifiers already in the document.
Completer :: #type proc(doc: ^Document, at: Pos, prefix: string, lang: ^Language, out: ^[dynamic]Completion)

COMPLETE_MAX :: 8 // rows shown
COMPLETE_MIN :: 2 // identifier characters that open the list while typing (a trigger opens it at once)

@(private)
COMPLETE_ITEM_TAG :: u64(100) // a candidate row's tag: this + its index (under RICH_ACTION_BASE)

// Complete_State: an editor's completion list. `from` is where an accept
// starts — the trigger, or the start of the identifier being typed — so
// accepting replaces the trigger and the query together.
@(private)
Complete_State :: struct {
	completer: Completer,
	trigger:   rune, // 0: identifiers as they are typed; otherwise the one character that opens it
	open:      bool,
	items:     [dynamic]Completion, // the candidates shown (strings owned, tree allocator)
	sel:       int,                 // the highlighted candidate
	from:      Pos,
}

// editor_complete gives an editor its completion source (see `Completer`).
// On a `code_editor` without one the editor offers the language's words and
// the identifiers nearby, opening on COMPLETE_MIN identifier characters or
// Ctrl+Space.
//
// `trigger` opens the list on one character instead, for prose:
// `editor_complete(ui, ed, files, trigger = '@')` on a `text_area` opens it
// when `@` is typed at the start of a word, asks the completer again on
// every keystroke with what follows as the prefix, and closes on a space,
// Escape, the caret leaving the word or the keyboard leaving the editor.
// Accepting replaces the trigger and the query with `insert`. While the
// list is open Enter and Tab accept without reaching `on_submit`, and
// Escape closes the list and nothing else. Stays until changed.
editor_complete :: proc(ui: ^Ui($Msg), n: Node, complete: Completer, trigger: rune = 0) {
	t := &ui.tree
	area := n
	if a, has := t.area_of_frame[n]; has do area = a
	if s := &t.areas[area]; s != nil {
		if s.complete.open && (s.complete.completer != complete || s.complete.trigger != trigger) do complete_close(ui, s)
		s.complete.completer, s.complete.trigger = complete, trigger
	}
}

// complete_trigger_len is how many bytes the trigger takes (0 without one).
@(private)
complete_trigger_len :: proc(c: ^Complete_State) -> int {
	if c.trigger == 0 do return 0
	_, n := utf8.encode_rune(c.trigger)
	return n
}

// complete_query is what the list is filtering on: the text between `from`
// (past the trigger) and the caret. ok = false when the caret has left it,
// which closes the list.
@(private)
complete_query :: proc(s: ^Text_Area_State) -> (query: string, ok: bool) {
	c := &s.complete
	if s.doc == nil || c.from.block != s.caret.block do return
	start := c.from.off + complete_trigger_len(c)
	if start > s.caret.off do return
	line := block_str(s.doc, s.caret.block)
	if s.caret.off > len(line) do return
	return line[start:s.caret.off], true
}

// complete_word_start is the start of the identifier run before the caret.
@(private)
complete_word_start :: proc(s: ^Text_Area_State) -> Pos {
	line := block_str(s.doc, s.caret.block)
	i := min(s.caret.off, len(line))
	for i > 0 && is_ident_char(line[i - 1]) do i -= 1
	return {s.caret.block, i}
}

@(private)
complete_items_clear :: proc(t: ^Tree, c: ^Complete_State) {
	for it in c.items {
		delete(it.label, t.allocator)
		if len(it.insert) > 0 do delete(it.insert, t.allocator)
		if len(it.detail) > 0 do delete(it.detail, t.allocator)
	}
	clear(&c.items)
}

@(private)
complete_state_destroy :: proc(t: ^Tree, c: ^Complete_State) {
	complete_items_clear(t, c)
	delete(c.items)
	c^ = {}
}

// complete_after_type: what typing does to the list. With a trigger, the
// trigger at the start of a word opens it and every keystroke after that
// asks the completer again; a space closes it. Without one (a code editor),
// an identifier opens it once the word is COMPLETE_MIN long.
@(private)
complete_after_type :: proc(ui: ^Ui($Msg), n: Node, s: ^Text_Area_State, typed: string) {
	c := &s.complete
	if c.completer == nil && !s.code.on do return
	if c.trigger != 0 {
		r, _ := utf8.decode_rune_in_string(typed)
		// One keystroke of the trigger at a word start opens it. A paste
		// that happens to start with it does not: nobody typed it, and the
		// caret is past whatever came with it.
		if r == c.trigger && utf8.rune_count_in_string(typed) == 1 {
			at := s.caret.off - len(typed)
			line := block_str(s.doc, s.caret.block)
			if at >= 0 && (at == 0 || !is_ident_char(line[at - 1])) {
				complete_open(ui, n, s, Pos{s.caret.block, at}, by_key = false)
				return
			}
		}
		if !c.open do return
		if len(typed) > 0 && (typed[0] == ' ' || typed[0] == '\t' || typed[0] == '\n') { // a space with nothing picked
			complete_close(ui, s)
			return
		}
		complete_open(ui, n, s, c.from, by_key = false)
		return
	}
	ident := len(typed) > 0 && is_ident_char(typed[0])
	if !ident {
		if c.open do complete_close(ui, s)
		return
	}
	from := complete_word_start(s)
	if c.open || s.caret.off - from.off >= COMPLETE_MIN do complete_open(ui, n, s, from, by_key = false)
}

// complete_open gathers the candidates for the query that starts at `from`
// and shows them; nothing to show closes the list. `by_key` is Ctrl+Space,
// which opens it with no prefix at all.
@(private)
complete_open :: proc(ui: ^Ui($Msg), n: Node, s: ^Text_Area_State, from: Pos, by_key: bool) {
	t := &ui.tree
	c := &s.complete
	if s.readonly || s.doc == nil do return
	if c.items == nil do c.items = make([dynamic]Completion, t.allocator) // the candidates it keeps are the tree's, not a frame's
	c.from = from
	query, ok := complete_query(s)
	if !ok {
		complete_close(ui, s)
		return
	}
	if !by_key && c.trigger == 0 && len(query) < COMPLETE_MIN {
		complete_close(ui, s)
		return
	}
	found := make([dynamic]Completion, context.temp_allocator)
	if c.completer != nil {
		c.completer(s.doc, s.caret, query, s.code.lang if s.code.on else nil, &found)
	} else {
		default_completer(s.doc, s.caret, query, s.code.lang, &found)
	}
	complete_items_clear(t, c)
	for f in found {
		if len(f.label) == 0 do continue
		append(&c.items, Completion{
			label = strings.clone(f.label, t.allocator),
			insert = strings.clone(f.insert, t.allocator) if len(f.insert) > 0 else "",
			detail = strings.clone(f.detail, t.allocator) if len(f.detail) > 0 else "",
			kind = f.kind,
		})
	}
	c.sel = 0
	was := c.open
	c.open = len(c.items) > 0
	if c.open || was do ask_rebuild(ui)
}

@(private)
complete_close :: proc(ui: ^Ui($Msg), s: ^Text_Area_State) {
	c := &s.complete
	if !c.open do return
	c.open = false
	complete_items_clear(&ui.tree, c)
	ask_rebuild(ui)
}

@(private)
complete_move :: proc(ui: ^Ui($Msg), s: ^Text_Area_State, dir: int) {
	c := &s.complete
	if len(c.items) == 0 do return
	c.sel = ((c.sel + dir) % len(c.items) + len(c.items)) % len(c.items)
	ask_rebuild(ui)
}

// complete_accept replaces the trigger and the query with the candidate.
@(private)
complete_accept :: proc(ui: ^Ui($Msg), n: Node, s: ^Text_Area_State, i: int) {
	c := &s.complete
	if i < 0 || i >= len(c.items) do return
	if _, ok := complete_query(s); !ok {
		complete_close(ui, s)
		return
	}
	it := c.items[i]
	ins := strings.clone(it.insert if len(it.insert) > 0 else it.label, context.temp_allocator) // closing frees the items
	from := c.from
	complete_close(ui, s)
	area_replace(ui, n, s, from, s.caret, ins)
}

// complete_key: the keys the list takes while it is open. Called before the
// editor's own keys and before the area's, so Enter accepts a candidate
// rather than submitting and Escape closes the list rather than reaching
// the app.
@(private)
complete_key :: proc(ui: ^Ui($Msg), n: Node, s: ^Text_Area_State, key: Key, mods: Mods) -> bool {
	if !s.complete.open do return false
	#partial switch key {
	case .Up:     complete_move(ui, s, -1); return true
	case .Down:   complete_move(ui, s, +1); return true
	case .Enter, .Tab:
		if .Ctrl in mods || .Alt in mods || .Super in mods do return false // a bound chord is the window's
		complete_accept(ui, n, s, s.complete.sel)
		return true
	case .Escape:
		complete_close(ui, s)
		return true
	case .Left, .Right, .Home, .End, .Page_Up, .Page_Down:
		complete_close(ui, s) // the caret leaves the word; the key itself still moves it
	}
	return false
}

// complete_click accepts the candidate that was clicked.
@(private)
complete_click :: proc(ui: ^Ui($Msg), n: Node) -> bool {
	t := &ui.tree
	area, ok := t.editor_ctl_of[n]
	if !ok do return false
	d := node_get(t, n)
	s := &t.areas[area]
	if d == nil || s == nil || !s.complete.open || d.access.role != .List_Item do return false
	if d.tag < COMPLETE_ITEM_TAG || d.tag >= COMPLETE_ITEM_TAG + u64(len(s.complete.items)) do return false
	complete_accept(ui, area, s, int(d.tag - COMPLETE_ITEM_TAG))
	return true
}

// complete_tick closes a list the keyboard has left. Called from the
// editors' tick.
@(private)
complete_tick :: proc(ui: ^Ui($Msg)) {
	for n, &s in ui.tree.areas {
		if s.complete.open && ui.tree.focus != n do complete_close(ui, &s)
	}
}

// complete_build shows the candidates in a popover under the caret. The
// kind badge is a code editor's (its letters are a language's), so a plain
// editor's list is the label and its detail.
@(private)
complete_build :: proc(ui: ^Ui($Msg), area: Node, s: ^Text_Area_State, loc: runtime.Source_Code_Location) {
	t := &ui.tree
	th := &t.theme
	c := &s.complete
	d := node_get(t, area)
	if d == nil do return
	k := (u64(area) * 0x9E37_79B9_7F4A_7C15) | 2
	pop, created := overlay_begin(ui, k, loc)
	popover_style(ui, pop, created, area, .Below, 0, true)
	pd := node_get(t, pop)
	pd.access.role = .List
	set_name(t, pop, "Completions")
	// at the caret's line, under it, backed up to the start of what is being
	// replaced where the cells are all one width (a code editor's mono face)
	line, _, x := caret_line(t, s, s.caret)
	scroll := scroll_offset(t, area)
	inner := input_inner(d)
	back := f32(max(s.caret.off - c.from.off, 0)) * s.code.adv if s.code.on else 0
	at := [2]f32{inner.x + area_text_x(s) - scroll.x + x - back - th.space[.sm], inner.y - scroll.y + block_top(t, s, s.caret.block) + f32(line + 1) * s.line_h + 2}
	// Near the window's bottom the card flips above `at`, and must clear the
	// caret's own line too or it covers the query being typed.
	t.overlay_rules[pop] = {fixed = true, at = at, at_avoid = area_line_h(t, s, s.caret.block) + 4}
	// sized to its widest row between the bounds: never the window's width
	set_layout(t, pop, Layout_Props{axis = .Column, align = .Stretch, padding = {th.space[.xs], th.space[.xs], th.space[.xs], th.space[.xs]}, min_w = 240, max_w = 460})
	first := 0
	if c.sel >= COMPLETE_MAX do first = c.sel - COMPLETE_MAX + 1
	for i := first; i < len(c.items) && i < first + COMPLETE_MAX; i += 1 {
		it := c.items[i]
		item, icreated := reconcile_child(ui, .Box, u64(i + 1), loc)
		id := node_get(t, item)
		if icreated do id.access.role = .List_Item
		set_name(t, item, it.label)
		id.tag = COMPLETE_ITEM_TAG + u64(i)
		t.editor_ctl_of[item] = area
		picked := i == c.sel
		if picked { id.access.states += {.Selected} } else { id.access.states -= {.Selected} }
		set_layout(t, item, Layout_Props{axis = .Row, align = .Center, justify = .Space_Between, gap = th.space[.md], padding = {th.space[.xxs], th.space[.sm], th.space[.xxs], th.space[.xs]}})
		st := id.style
		st.radius = th.radius.sm
		st.bg = th.color.primary_container if picked else Color{}
		set_style(t, item, st)
		open_scope(ui, item, loc)
		lead := row(ui, gap = .sm, align = .Center, loc = loc)
		set_role(t, lead, .None)
		if s.code.on { // a kind badge: one letter in the token's colour
			kind_col := code_token_color(th, it.kind)
			badge := box(ui, width = 18, height = 18, radius = th.radius.xs, bg = Color{kind_col.r, kind_col.g, kind_col.b, 0.22}, loc = loc)
			set_layout(t, badge, Layout_Props{axis = .Row, align = .Center, justify = .Center, width = 18, height = 18})
			open_scope(ui, badge, loc)
			bl := text(ui, code_kind_letter(it.kind), role = .Caption, color = kind_col, nowrap = true, loc = loc)
			set_role(t, bl, .None)
			close_scope(ui)
		}
		col := th.color.on_primary_container if picked else th.color.on_surface
		lbl := text(ui, it.label, role = .Body, color = col, nowrap = true, ellipsis = .End, loc = loc)
		set_role(t, lbl, .None)
		end(ui)
		if len(it.detail) > 0 {
			dt := text(ui, it.detail, role = .Caption, muted = !picked, color = th.color.on_primary_container if picked else Color{}, nowrap = true, loc = loc)
			set_role(t, dt, .None)
		}
		close_scope(ui)
	}
	end(ui)
}
