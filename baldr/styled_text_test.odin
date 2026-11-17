package baldr

@(require) import "core:strings"
@(require) import "core:testing"

// A paragraph of styled runs the app built.
//
// The messaging subset (`*bold*`, `_italic_`, `~strike~`, `` `code` ``,
// auto-linked URLs) is not CommonMark, so a chat parses its own and hands
// the toolkit runs. These check the three things that makes it worth being
// a widget rather than a row of `text` nodes: the runs are *drawn* in their
// styles, the paragraph wraps and selects as one piece across them, and a
// link reaches `update`.
when ODIN_TEST || #config(BALDR_TESTS, false) {

@(private = "file")
St_Msg :: union { string }

// "Hello bold code link." with a run each.
@(private = "file")
ST_TEXT :: "Hello bold code link."

// Hello |bold |code |link|. — a package-level var, not returned from a
// proc: a slice literal returned from one points at the stack frame it was
// made in.
@(private = "file")
ST_RUNS := []Run{
	{end = 6},
	{end = 11, attrs = {.Bold}},
	{end = 16, attrs = {.Code}},
	{end = 20, attrs = {.Link}, href = "https://example.invalid/x"},
	{end = 21},
}

@(private = "file")
st_build :: proc(ui: ^Ui(St_Msg), w: f32) -> Node {
	set_viewport(&ui.tree, {w, 300})
	begin_view(ui)
	column(ui, padding = .md)
	n := styled_text(ui, ST_TEXT, ST_RUNS,
		on_link = proc(e: Ev(string)) -> St_Msg { return e.value }, width = w - 32, key = 1)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {w, 300})
	return n
}

// Every run is drawn in its own style, which a single `text` node cannot
// do.
@(test)
styled_runs_are_drawn_in_their_own_styles :: proc(t: ^testing.T) {
	ui: Ui(St_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	n := st_build(&ui, 420)
	testing.expect(t, n != NODE_NONE, "the widget built")

	bold_semibold, code_washed, link_underlined := false, false, false
	accent := ui.tree.theme.color.primary
	for c in draw_list(&ui.tree) {
		#partial switch v in c {
		case Draw_Text:
			if v.str == "bold " && v.weight == .Semibold do bold_semibold = true
		case Draw_Rect:
			// the inline code wash and the link's underline are both rects;
			// the underline is a hairline in the accent, the wash is not
			if v.rect.h <= 1.5 && v.color.rgb == accent.rgb do link_underlined = true
			if v.rect.h > 1.5 && v.radius > 0 do code_washed = true
		}
	}
	testing.expect(t, bold_semibold, "the bold run is drawn semibold")
	testing.expect(t, code_washed, "the code run is washed")
	testing.expect(t, link_underlined, "the link run is underlined in the accent")
}

// One paragraph, not a row of nodes: a narrow box wraps *inside* the text,
// and the widget is as tall as the lines it took.
@(test)
a_styled_paragraph_wraps_as_one_piece :: proc(t: ^testing.T) {
	ui: Ui(St_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	wide := st_build(&ui, 420)
	wide_h := node_get(&ui.tree, wide).abs.h

	ui2: Ui(St_Msg)
	ui_init(&ui2)
	defer ui_destroy(&ui2)
	narrow := st_build(&ui2, 150)
	narrow_h := node_get(&ui2.tree, narrow).abs.h

	s := &ui2.tree.styled[narrow]
	testing.expect(t, s != nil && len(s.lay.lines) > 1, "the narrow one wrapped onto more than one line")
	testing.expectf(t, narrow_h > wide_h, "and is taller for it (%.1f vs %.1f)", narrow_h, wide_h)
}

// A drag across the runs selects across them, and what it copies is plain
// text: the styles are how it is drawn, not what it is.
@(test)
a_styled_selection_copies_as_plain_text :: proc(t: ^testing.T) {
	ui: Ui(St_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	n := st_build(&ui, 420)
	d := node_get(&ui.tree, n)
	r := d.abs

	pointer_button(&ui, .Left, true, {r.x + 1, r.y + r.h / 2})
	pointer_move(&ui, {r.x + r.w - 1, r.y + r.h / 2})
	pointer_button(&ui, .Left, false, {r.x + r.w - 1, r.y + r.h / 2})

	s := &ui.tree.styled[n]
	lo, hi := styled_sel(s)
	testing.expectf(t, hi > lo, "a drag selected something (%d..%d)", lo, hi)
	got := styled_text_selected(s, context.temp_allocator)
	testing.expect(t, len(got) > 0, "and it has text")
	// plain: no markers, and a substring of the source
	testing.expectf(t, strings.contains(ST_TEXT, got), "copied %q is plain text from the paragraph", got)
}

// A click on the link run reaches update with its href; a click on ordinary
// text does not.
@(test)
clicking_a_link_run_sends_its_href :: proc(t: ^testing.T) {
	ui: Ui(St_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	n := st_build(&ui, 420)
	d := node_get(&ui.tree, n)
	s := &ui.tree.styled[n]
	lay := &s.lay
	testing.expect(t, len(lay.lines) > 0, "it laid out")

	// the middle of the link run, through the layout rather than by guessing
	li := rich_line_of(lay, 17, len(ST_TEXT))
	x := (rich_x(lay, li, 16) + rich_x(lay, li, 20)) / 2
	at := [2]f32{d.abs.x + lay.lines[li].x + x, d.abs.y + lay.lines[li].y + lay.line_h / 2}

	before := len(ui.msgs)
	pointer_button(&ui, .Left, true, at)
	pointer_button(&ui, .Left, false, at)
	sent := ""
	for m in ui.msgs[before:] do if v, ok := m.(string); ok do sent = v
	testing.expect_value(t, sent, "https://example.invalid/x")

	// …and the plain first run sends nothing
	li0 := rich_line_of(lay, 2, len(ST_TEXT))
	x0 := rich_x(lay, li0, 2)
	at0 := [2]f32{d.abs.x + lay.lines[li0].x + x0, d.abs.y + lay.lines[li0].y + lay.line_h / 2}
	before = len(ui.msgs)
	pointer_button(&ui, .Left, true, at0)
	pointer_button(&ui, .Left, false, at0)
	none := true
	for m in ui.msgs[before:] do if _, ok := m.(string); ok do none = false
	testing.expect(t, none, "a click on ordinary text is not a link")
}

// It is a Text in the accessibility tree, named by what it says — a reader
// should hear the sentence, not five runs.
@(test)
a_styled_paragraph_reads_as_one_text :: proc(t: ^testing.T) {
	ui: Ui(St_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	n := st_build(&ui, 420)
	d := node_get(&ui.tree, n)
	testing.expect_value(t, d.access.role, Role.Text)
	testing.expect_value(t, d.access.name, ST_TEXT)
}

}
