package baldr

@(require) import "core:strings"
@(require) import "core:testing"
@(require) import "core:time"

// A pointer move over a long line costs O(line), not O(line × block).
//
// `grapheme_next(str, i)` iterates from the start of `str` on every call, so
// `span_hit_disp` walks the span's own bytes once rather than stepping
// through the whole block. One test pins that this is correct (a span is cut
// between clusters), the other that a drag across a 2,000-character line
// stays well inside a frame.
when ODIN_TEST || #config(BALDR_TESTS, false) {

@(private = "file")
Ll_Msg :: union { int }

@(private = "file")
ll_build :: proc(ui: ^Ui(Ll_Msg), doc: ^Document, wrap: bool) -> Node {
	set_viewport(&ui.tree, {900, 900})
	begin_view(ui)
	e := text_area(ui, doc, label = "SQL", width = 640, height = 300)
	editor_options(ui, e, wrap = wrap, readonly = true, max_lines = 16)
	end_view(ui)
	frame(&ui.tree, {900, 900})
	return e
}

@(private = "file")
ll_settled :: proc(ui: ^Ui(Ll_Msg), doc: ^Document, wrap: bool) -> Node {
	ed := ll_build(ui, doc, wrap)
	for _ in 0 ..< 4 do ed = ll_build(ui, doc, wrap)
	return ed
}

// ll_drag_ms is the cost of one pointer move while dragging a selection
// right across the box.
@(private = "file")
ll_drag_ms :: proc(ui: ^Ui(Ll_Msg), ed: Node, moves: int) -> f64 {
	r := node_get(&ui.tree, ed).abs
	set_focus(&ui.tree, ed, true)
	pointer_button(ui, .Left, true, {r.x + 4, r.y + 4})
	start := time.now()
	for i in 0 ..< moves {
		k := f32(i) / f32(max(moves - 1, 1))
		pointer_move(ui, {r.x + 4 + k * (r.w - 8), r.y + 4 + k * (r.h - 8)})
	}
	ms := time.duration_milliseconds(time.since(start)) / f64(moves)
	pointer_button(ui, .Left, false, {r.x + r.w - 4, r.y + r.h - 4})
	return ms
}

// The walk iterates `str[sp.start:sp.end]`, which is only right because a
// span's ends are cluster boundaries: the rules that need preceding context
// (regional indicators, ZWJ sequences) join within a cluster, never across
// one. Every offset a click produces must be a boundary of the block's text.
@(test)
clicking_a_line_of_clusters_never_lands_inside_one :: proc(t: ^testing.T) {
	// flags (regional indicator pairs), a ZWJ family, and a combining accent:
	// the three shapes whose boundaries need context
	unit := "🇬🇧 á 👨‍👩‍👧 déjà 🇫🇷 "
	line := strings.repeat(unit, 40)
	defer delete(line)
	doc := document_make(line)
	defer document_destroy(&doc)
	ui: Ui(Ll_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	ed := ll_settled(&ui, &doc, true)
	d := node_get(&ui.tree, ed)
	s := &ui.tree.areas[ed]
	r := d.abs

	text := area_text(&ui.tree, s, 0)
	checked := 0
	for i in 0 ..< 60 {
		k := f32(i) / 59
		pos := [2]f32{r.x + 4 + k * (r.w - 8), r.y + 4 + k * (r.h - 8)}
		p := area_hit(&ui.tree, ed, d, s, pos)
		if p.block != 0 do continue
		off := clamp(p.off, 0, len(text))
		testing.expectf(t, grapheme_snap(text, off) == off,
			"a click landed at %d, inside a cluster (its boundary is %d)", off, grapheme_snap(text, off))
		checked += 1
	}
	testing.expectf(t, checked > 20, "enough clicks landed in the text to mean anything (%d)", checked)
}

// An absolute budget, not a ratio: a whole-block walk slows the long and the
// short line alike, so their ratio hides it. 2 ms leaves a slow machine wide
// headroom over a linear walk and still fails a whole-block one.
@(test)
dragging_across_a_long_line_stays_inside_a_frame :: proc(t: ^testing.T) {
	BUDGET_MS :: 2.0
	sql := strings.repeat("SELECT a, b, c FROM t WHERE x = 1 AND y = 2 ", 46) // ~2,000 chars, one line
	defer delete(sql)
	doc := document_make(sql)
	defer document_destroy(&doc)

	for wrap in ([2]bool{true, false}) {
		ui: Ui(Ll_Msg)
		ui_init(&ui)
		defer ui_destroy(&ui)
		ed := ll_settled(&ui, &doc, wrap)
		ms := ll_drag_ms(&ui, ed, 40)
		// Without wrap the line is one span, so the walk is the whole 2,000
		// characters: linear, which is right.
		testing.expectf(t, ms < BUDGET_MS, "wrap=%v: %.3f ms a pointer move, over the %.1f ms budget", wrap, ms, BUDGET_MS)
	}
}

}
