package baldr

@(require) import "core:strings"
@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: they sit behind this `when` so an app does not pay
// for them (see canvas_test.odin).
when ODIN_TEST || #config(BALDR_TESTS, false) {

// The mark lists below are named `[]Mark{…}` locals, not literals inside the
// call: inline, the element type, the struct type and the nested Pos are all
// inferred through the parameter, which costs the compiler many minutes and
// gigabytes. See AGENTS.md.

// A sentence focus draws everything but the caret's sentence faded and
// follows the caret, so the fade cannot live in the document's runs, where a
// caret move would become an edit. These marks are display only: never in
// the document, never copied or exported, and a fresh list every build.

@(private = "file")
Mt_Msg :: union { int }

@(private = "file")
TINT :: Color{0.2, 0.7, 0.4, 1}

// mt_painted builds a plain editor over `doc` with `marks` on it, and hands
// back every piece of text it painted (temp memory).
@(private = "file")
mt_painted :: proc(ui: ^Ui(Mt_Msg), doc: ^Document, marks: []Mark) -> []Draw_Text {
	begin_view(ui)
	column(ui, padding = .none)
	n := text_area(ui, doc, width = 600, height = 200)
	editor_marks(ui, n, marks)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {600, 300})
	out := make([dynamic]Draw_Text, context.temp_allocator)
	for _, l in ui.tree.layers do for c in l.cmds {
		if v, ok := c.(Draw_Text); ok && len(v.str) > 0 do append(&out, v)
	}
	return out[:]
}

@(private = "file")
mt_piece :: proc(painted: []Draw_Text, want: string) -> (Draw_Text, bool) {
	for p in painted do if p.str == want do return p, true
	return {}, false
}

// Dim draws the words in the muted colour, and only the words it covers.
@(test)
a_dim_mark_fades_the_words_it_covers :: proc(t: ^testing.T) {
	ui: Ui(Mt_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	doc := document_make("One two. Three four.")
	defer document_destroy(&doc)

	plain := mt_painted(&ui, &doc, nil)
	whole, had := mt_piece(plain, "One two. Three four.")
	testing.expect(t, had, "with no marks it is one run, as it always was")

	dim_mark := []Mark{{from = {0, 0}, to = {0, 9}, kind = .Dim}}
	faded := mt_painted(&ui, &doc, dim_mark)
	dim, ok1 := mt_piece(faded, "One two. ")
	rest, ok2 := mt_piece(faded, "Three four.")
	testing.expect(t, ok1 && ok2, "it is drawn in two pieces now")
	testing.expect_value(t, dim.color, with_alpha(ui.tree.theme.color.on_surface_muted, dim.color.a))
	testing.expect_value(t, rest.color, whole.color) // the rest is untouched
	testing.expect(t, dim.pos.x < rest.pos.x, "and they are in order")
	testing.expect_value(t, dim.pos.x, whole.pos.x) // the first piece starts where the line does
}

// Tint draws them in the mark's own colour, and the last mark wins where
// two cover the same words.
@(test)
a_tint_mark_colours_the_words_and_the_last_one_wins :: proc(t: ^testing.T) {
	ui: Ui(Mt_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	doc := document_make("alpha beta")
	defer document_destroy(&doc)

	two := []Mark{
		{from = {0, 0}, to = {0, 10}, kind = .Tint, color = TINT},
		{from = {0, 0}, to = {0, 5}, kind = .Dim}, // over the first word, later: it wins
	}
	painted := mt_painted(&ui, &doc, two)
	first, ok1 := mt_piece(painted, "alpha")
	second, ok2 := mt_piece(painted, " beta")
	testing.expect(t, ok1 && ok2, "two runs of two colours")
	testing.expect_value(t, first.color, with_alpha(ui.tree.theme.color.on_surface_muted, first.color.a))
	testing.expect_value(t, second.color, with_alpha(TINT, second.color.a))
}

// Strike draws a line through the words and leaves their colour alone —
// "consider cutting this", not "this is something else".
@(test)
a_strike_mark_rules_through_without_recolouring :: proc(t: ^testing.T) {
	ui: Ui(Mt_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	doc := document_make("very really quite")
	defer document_destroy(&doc)

	struck := []Mark{{from = {0, 0}, to = {0, 4}, kind = .Strike}}
	painted := mt_painted(&ui, &doc, struck)
	whole, had := mt_piece(painted, "very really quite")
	testing.expect(t, had, "the text is still one run: nothing recoloured it")
	testing.expect(t, whole.color.r > 0 || whole.color.g > 0 || whole.color.b > 0)

	rules := 0
	for _, l in ui.tree.layers do for c in l.cmds {
		if r, ok := c.(Draw_Rect); ok && r.rect.h == 1 && r.color == with_alpha(ui.tree.theme.color.warning, r.color.a) do rules += 1
	}
	testing.expect(t, rules >= 1, "and a line goes through it")
}

// The usual case pays nothing: with no recolouring mark the block is the
// one run it always was, which is what keeps a fade that moves with the
// caret cheap.
@(test)
marks_that_do_not_recolour_leave_the_text_in_one_piece :: proc(t: ^testing.T) {
	ui: Ui(Mt_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	doc := document_make("a spell chequer")
	defer document_destroy(&doc)

	around := []Mark{
		{from = {0, 2}, to = {0, 7}, kind = .Warning, message = "spelling"},
		{from = {0, 0}, to = {0, 1}, kind = .Highlight},
	}
	painted := mt_painted(&ui, &doc, around)
	_, had := mt_piece(painted, "a spell chequer")
	testing.expect(t, had, "still one run")
	testing.expect(t, !mark_recolours(.Warning) && !mark_recolours(.Highlight))
	testing.expect(t, mark_recolours(.Dim) && mark_recolours(.Tint))
	testing.expect(t, !mark_recolours(.Strike), "a strike draws over, it does not recolour")
}

// A fade covering most of a long document is one mark, and asking for the
// runs of a block it does not touch costs nothing.
@(test)
a_fade_over_most_of_a_document_is_one_mark :: proc(t: ^testing.T) {
	ui: Ui(Mt_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	body := strings.repeat("A sentence here. ", 40, context.temp_allocator)
	doc := document_make(body)
	defer document_destroy(&doc)

	begin_view(&ui)
	column(&ui, padding = .none)
	n := text_area(&ui, &doc, width = 600, height = 200)
	wide := []Mark{{from = {0, 0}, to = {0, 100}, kind = .Dim}}
	editor_marks(&ui, n, wide)
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {600, 300})

	area, s := editor_area(&ui.tree, n)
	testing.expect(t, s != nil, "the area kept its state")
	tints := area_mark_tints(&ui.tree, s, 0)
	testing.expect_value(t, len(tints), 1) // one run, not one per word
	testing.expect_value(t, tints[0].from, 0)
	testing.expect_value(t, tints[0].to, 100)
	_ = area
}

}
