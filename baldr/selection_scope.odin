package baldr

// One selection across several messages.
//
// Selecting *within* a reply is the markdown view's own job, and within a
// document the editor's. What neither can own is a selection that starts in
// one message and ends in another: somebody above them has to say which
// views a drag has entered, tell each one which part of the selection is
// theirs, and copy them in order. That somebody is a *scope* — a container
// an app marks with `selection_scope`, usually the column its conversation
// is built in.
//
// The scope owns no text and paints nothing. It keeps two ends — a view and
// a byte offset in it — and writes each view's own selection from them, so
// the drawing, the copying and the offsets stay exactly where they were.
// That is also why a streaming reply cannot disturb it: the ends name a
// node and an offset into what that node holds, and bytes landing at the
// end of the last message move neither.

import "core:strings"

// Sel_Scope is one scope's selection: where it started, where it is now,
// and whether a drag is still laying it down.
@(private)
Sel_Scope :: struct {
	anchor:    Node,
	anchor_at: int,
	focus:     Node,
	focus_at:  int,
	dragging:  bool,
}

// selection_scope makes `n` the owner of one selection across the text
// views inside it (a conversation's column), so a drag that starts in one
// message and ends in another selects everything between, each view drawing
// its own part, and Ctrl+C copies the lot in order, separated by blank
// lines. It gathers the markdown views and text areas (read-only included)
// inside it, in build order. A selection within one view stays that view's
// own (double-click a word, triple-click a block) and becomes the scope's
// only when the drag leaves it. Escape lets the selection go; a press
// anywhere in the scope starts a new one. The setting stays until changed
// (`on = false` removes it).
selection_scope :: proc(ui: ^Ui($Msg), n: Node, on := true, loc := #caller_location) {
	t := &ui.tree
	if node_get(t, n) == nil do return
	if !on {
		sel_scope_clear(t, n)
		delete_key(&t.sel_scopes, n)
		return
	}
	if _, has := t.sel_scopes[n]; !has {
		t.sel_scopes[n] = Sel_Scope{anchor = NODE_NONE, focus = NODE_NONE}
	}
}

// sel_scope_of is the nearest scope `n` sits in, NODE_NONE when it is in
// none. A scope inside a scope is the inner one's.
@(private)
sel_scope_of :: proc(t: ^Tree, n: Node) -> Node {
	for cur := n; cur != NODE_NONE; {
		if _, is := t.sel_scopes[cur]; is do return cur
		d := node_get(t, cur)
		if d == nil do break
		cur = d.parent
	}
	return NODE_NONE
}

// sel_is_view says whether `n` holds text a scope's selection can run
// through. Two kinds do: a markdown view and a text area (the editors are
// text areas, a read-only one included).
@(private)
sel_is_view :: proc(t: ^Tree, n: Node) -> bool {
	if s, is := &t.md_views[n]; is && s.md != nil do return true
	if s, is := &t.areas[n]; is && s.doc != nil do return true
	return false
}

// sel_views lists a scope's text views in the order they were built, which
// is the order they are read in and the order they are copied in.
@(private)
sel_views :: proc(t: ^Tree, scope: Node, out: ^[dynamic]Node) {
	d := node_get(t, scope)
	if d == nil || .Hidden in d.flags do return
	if scope != NODE_NONE && sel_is_view(t, scope) do append(out, scope)
	for c := d.first; c != NODE_NONE; {
		cd := node_get(t, c)
		if cd == nil do break
		sel_views(t, c, out)
		c = cd.next
	}
}

// sel_span is how far a view's offsets go — the end of everything it holds.
@(private)
sel_span :: proc(t: ^Tree, n: Node) -> int {
	if s, is := &t.md_views[n]; is && s.md != nil do return len(s.md.src)
	if s, is := &t.areas[n]; is && s.doc != nil do return document_flat_off(s.doc, document_end(s.doc))
	return 0
}

// sel_hit is the offset in `n` under an absolute point.
@(private)
sel_hit :: proc(t: ^Tree, n: Node, pos: [2]f32) -> int {
	if s, is := &t.md_views[n]; is && s.md != nil do return md_view_at(t, n, s, pos)
	if s, is := &t.areas[n]; is && s.doc != nil {
		d := node_get(t, n)
		if d == nil do return 0
		return document_flat_off(s.doc, area_hit(t, n, d, s, pos))
	}
	return 0
}

// sel_put gives a view its part of the scope's selection. The fields are
// set rather than `editor_select` called, because that asks to scroll the
// caret into view and a scope sets every view it covers: a drag would fling
// each message to its end.
@(private)
sel_put :: proc(t: ^Tree, n: Node, lo, hi: int) {
	if s, is := &t.md_views[n]; is && s.md != nil {
		if s.sel_a != lo || s.sel_b != hi {
			s.sel_a, s.sel_b = lo, hi
			mark_paint_dirty(t, n)
		}
		return
	}
	if s, is := &t.areas[n]; is && s.doc != nil {
		a, c := document_pos_at(s.doc, lo), document_pos_at(s.doc, hi)
		if s.anchor != a || s.caret != c {
			s.anchor, s.caret = a, c
			mark_paint_dirty(t, n)
		}
	}
}

// sel_part_text is what a view has selected, as text ready for a clipboard.
@(private)
sel_part_text :: proc(t: ^Tree, n: Node, allocator := context.temp_allocator) -> string {
	if s, is := &t.md_views[n]; is && s.md != nil do return md_view_selected_text(t, n, allocator)
	if s, is := &t.areas[n]; is && s.doc != nil {
		lo, hi := pos_order(s.anchor, s.caret)
		if lo == hi do return ""
		return document_range_text(s.doc, lo, hi, allocator)
	}
	return ""
}

// sel_scope_clear lets go of a scope's selection, and of every part of it
// the views are still drawing.
@(private)
sel_scope_clear :: proc(t: ^Tree, scope: Node) {
	sc, has := &t.sel_scopes[scope]
	if !has do return
	views := make([dynamic]Node, context.temp_allocator)
	sel_views(t, scope, &views)
	for v in views do sel_put(t, v, 0, 0)
	sc.anchor, sc.focus, sc.anchor_at, sc.focus_at, sc.dragging = NODE_NONE, NODE_NONE, 0, 0, false
}

// sel_scope_spans says whether a scope's selection covers more than one
// view — the case the scope exists for. Within one view it is that view's
// own selection and the scope keeps out of the way.
@(private)
sel_scope_spans :: proc(t: ^Tree, scope: Node) -> bool {
	sc, has := t.sel_scopes[scope]
	return has && sc.anchor != NODE_NONE && sc.focus != NODE_NONE && sc.anchor != sc.focus
}

// sel_scope_covers says whether `n` sits in a scope whose selection runs
// across views. An editor draws its selection while focus is inside it,
// which is right for a document and wrong for a message in the middle of a
// selection that started two messages above: it has to show its part.
@(private)
sel_scope_covers :: proc(t: ^Tree, n: Node) -> bool {
	scope := sel_scope_of(t, n)
	return scope != NODE_NONE && sel_scope_spans(t, scope)
}

// sel_scope_apply writes the scope's two ends into the views between them:
// the end views get the part on their side of the offset, the views in
// between are wholly selected, the rest let go.
@(private)
sel_scope_apply :: proc(t: ^Tree, scope: Node) {
	sc, has := &t.sel_scopes[scope]
	if !has || sc.anchor == NODE_NONE || sc.focus == NODE_NONE do return
	views := make([dynamic]Node, context.temp_allocator)
	sel_views(t, scope, &views)
	ai, fi := -1, -1
	for v, i in views {
		if v == sc.anchor do ai = i
		if v == sc.focus do fi = i
	}
	if ai < 0 || fi < 0 do return
	first, last := ai, fi
	from, to := sc.anchor_at, sc.focus_at
	if fi < ai { // dragged backwards: the first view in order holds the low end
		first, last = fi, ai
		from, to = sc.focus_at, sc.anchor_at
	}
	for v, i in views {
		switch {
		case i < first || i > last: sel_put(t, v, 0, 0)
		case i == first && i == last: sel_put(t, v, from, to)
		case i == first: sel_put(t, v, from, sel_span(t, v))
		case i == last:  sel_put(t, v, 0, to)
		case:            sel_put(t, v, 0, sel_span(t, v))
		}
	}
}

// sel_scope_text is the whole selection, in the order the messages are
// read: each view's part, with a blank line between them, which is how a
// page pastes a selection that crossed its paragraphs.
@(private)
sel_scope_text :: proc(t: ^Tree, scope: Node, allocator := context.temp_allocator) -> string {
	views := make([dynamic]Node, context.temp_allocator)
	sel_views(t, scope, &views)
	sb := strings.builder_make(allocator)
	for v in views {
		part := sel_part_text(t, v, context.temp_allocator)
		if len(part) == 0 do continue
		if strings.builder_len(sb) > 0 do strings.write_string(&sb, "\n\n")
		strings.write_string(&sb, part)
	}
	return strings.to_string(sb)
}

// sel_scope_press starts a scope's selection where a press landed. The view
// under the pointer has already placed its own selection (a word for a
// double click, a block for a triple), so the anchor is taken from what it
// did rather than from the point: dragging out of a word-selection keeps
// the word, as it does in a document.
@(private)
sel_scope_press :: proc(t: ^Tree, hit: Node, shift: bool) {
	scope := sel_scope_of(t, hit)
	if scope == NODE_NONE do return
	sc, has := &t.sel_scopes[scope]
	if !has do return
	view := sel_nearest_view(t, hit)
	if view == NODE_NONE do return
	if shift && sc.anchor != NODE_NONE { // Shift+click extends what is there
		sc.focus, sc.focus_at = view, sel_own_focus(t, view)
		sel_scope_apply(t, scope)
		return
	}
	// a fresh selection: every other view in the scope lets go of its own
	views := make([dynamic]Node, context.temp_allocator)
	sel_views(t, scope, &views)
	for v in views do if v != view do sel_put(t, v, 0, 0)
	lo, hi := sel_own_range(t, view)
	sc.anchor, sc.anchor_at = view, lo
	sc.focus, sc.focus_at = view, hi
	sc.dragging = true
}

// sel_scope_drag follows the pointer: while it is inside the view the
// selection began in, that view's own drag is the selection. Once it leaves,
// the scope takes over and the view under the pointer becomes the far end.
@(private)
sel_scope_drag :: proc(ui: ^Ui($Msg), pos: [2]f32) -> bool {
	t := &ui.tree
	for scope, &sc in t.sel_scopes {
		if !sc.dragging || sc.anchor == NODE_NONE do continue
		view := sel_nearest_view(t, hit_test(t, pos))
		if view == NODE_NONE || sel_scope_of(t, view) != scope {
			if sc.anchor == sc.focus do continue // still in the one view: its own drag has it
			sel_scope_apply(t, scope) // off the messages: the selection stays where it reached
			return true
		}
		if view == sc.anchor && sc.anchor == sc.focus do return false // one view: its own drag has it
		at := sel_hit(t, view, pos)
		if view == sc.focus && at == sc.focus_at do return true // the pointer moved, the selection did not
		sc.focus, sc.focus_at = view, at
		sel_scope_apply(t, scope)
		ask_rebuild(ui) // an app showing what is selected asked to be told
		return true
	}
	return false
}

// sel_scope_release ends the drag; the selection stays as it is.
@(private)
sel_scope_release :: proc(t: ^Tree) {
	for _, &sc in t.sel_scopes do sc.dragging = false
}

// sel_nearest_view is the text view `n` is, or sits inside.
@(private)
sel_nearest_view :: proc(t: ^Tree, n: Node) -> Node {
	for cur := n; cur != NODE_NONE; {
		if sel_is_view(t, cur) do return cur
		d := node_get(t, cur)
		if d == nil do break
		cur = d.parent
	}
	return NODE_NONE
}

// sel_own_range is what a view has selected in its own offsets, low first.
@(private)
sel_own_range :: proc(t: ^Tree, n: Node) -> (lo, hi: int) {
	if s, is := &t.md_views[n]; is && s.md != nil do return min(s.sel_a, s.sel_b), max(s.sel_a, s.sel_b)
	if s, is := &t.areas[n]; is && s.doc != nil {
		a, c := pos_order(s.anchor, s.caret)
		return document_flat_off(s.doc, a), document_flat_off(s.doc, c)
	}
	return 0, 0
}

// sel_own_focus is the moving end of a view's own selection.
@(private)
sel_own_focus :: proc(t: ^Tree, n: Node) -> int {
	if s, is := &t.md_views[n]; is && s.md != nil do return s.sel_b
	if s, is := &t.areas[n]; is && s.doc != nil do return document_flat_off(s.doc, s.caret)
	return 0
}

// sel_scope_key gives a spanning selection its keys before the view with
// focus gets them: Ctrl+C copies the whole of it, Escape lets it go. A
// selection inside one view is that view's, and neither is taken from it.
@(private)
sel_scope_key :: proc(ui: ^Ui($Msg), key: Key, mods: Mods) -> bool {
	t := &ui.tree
	scope := sel_scope_of(t, t.focus)
	if scope == NODE_NONE do return false
	sc, has := &t.sel_scopes[scope]
	if !has do return false
	if shift_chord_bound(ui, key, mods) do return false // the app's own Ctrl+Shift+C / V / A wins
	spans := sel_scope_spans(t, scope)
	#partial switch key {
	case .A:
		// The first Ctrl+A is the message's own — it is the widget's key and
		// this lets it through. The second, with that message already whole,
		// takes the conversation: the escalation a person expects from an
		// editor, rather than a select-all that skips the obvious step.
		if .Ctrl not_in mods do return false
		view := sel_nearest_view(t, t.focus)
		if view == NODE_NONE do return false
		lo, hi := sel_own_range(t, view)
		if !spans && !(lo == 0 && hi == sel_span(t, view) && hi > 0) do return false
		views := make([dynamic]Node, context.temp_allocator)
		sel_views(t, scope, &views)
		if len(views) < 2 do return false // one message: its own Ctrl+A is the whole of it
		sc.anchor, sc.anchor_at = views[0], 0
		sc.focus, sc.focus_at = views[len(views) - 1], sel_span(t, views[len(views) - 1])
		sel_scope_apply(t, scope)
		ask_rebuild(ui)
		return true
	case .C:
		if !spans || .Ctrl not_in mods || t.clipboard.set == nil do return false
		text := sel_scope_text(t, scope, context.temp_allocator)
		if len(text) == 0 do return false
		return t.clipboard.set(t.clipboard.user, text)
	case .Escape:
		if !spans do return false
		sel_scope_clear(t, scope)
		ask_rebuild(ui)
		return true
	}
	return false
}

// selection_scope_text is what a scope has selected, as text: the messages
// it covers in order, separated by a blank line. "" when nothing is. The
// string is the frame's temp memory by default — clone what you keep.
selection_scope_text :: proc(t: ^Tree, scope: Node, allocator := context.temp_allocator) -> string {
	if _, has := t.sel_scopes[scope]; !has do return ""
	return sel_scope_text(t, scope, allocator)
}

// SEL_EDGE is how near the edge of the scroll a drag has to reach before
// the conversation starts moving under it, and SEL_EDGE_STEP how far it
// moves each time: a long reply and a drag upwards is the common case, and
// a selection that stops at the edge of the window is a selection a person
// cannot finish.
@(private) SEL_EDGE      :: f32(28)
@(private) SEL_EDGE_STEP :: f32(14)
@(private) SEL_EDGE_MS   :: f64(16)

// sel_drag_tick keeps a held drag going when the pointer has stopped at the
// edge: there are no more pointer events to act on, so the scroll moves on a
// timer and the drag is re-read against the content that came into view. It
// serves a scope's drag and a single reply's alike.
@(private)
sel_drag_tick :: proc(ui: ^Ui($Msg), now_ms: f64) {
	t := &ui.tree
	dragging := NODE_NONE
	for scope, &sc in t.sel_scopes do if sc.dragging do dragging = scope
	if dragging == NODE_NONE {
		for n, &s in t.md_views do if s.dragging do dragging = n
	}
	if dragging == NODE_NONE do return
	sn := scroll_ancestor(t, dragging)
	if sn == NODE_NONE do return
	st, has := &t.scrolls[sn]
	d := node_get(t, sn)
	if !has || d == nil || st.viewport.y <= 0 do return
	pos := ui.pointer.pos
	top := d.abs.y + d.layout.padding[0]
	bottom := top + st.viewport.y
	dy: f32
	switch {
	case pos.y < top + SEL_EDGE:    dy = (pos.y - (top + SEL_EDGE)) / SEL_EDGE
	case pos.y > bottom - SEL_EDGE: dy = (pos.y - (bottom - SEL_EDGE)) / SEL_EDGE
	}
	if dy == 0 do return
	step := clamp(dy, -1, 1) * SEL_EDGE_STEP
	if scroll_to(t, sn, st.offset + {0, step}) {
		if !sel_scope_drag(ui, pos) do md_view_pointer_move(ui, pos) // the text under the pointer changed
		ask_rebuild(ui)
	}
	tree_wake_at(t, now_ms + SEL_EDGE_MS, dragging) // …and again while the pointer stays there
}
