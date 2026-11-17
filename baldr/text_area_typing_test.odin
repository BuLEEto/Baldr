package baldr

@(require) import "core:strings"
@(require) import "core:testing"

// Test files are part of the package, so without this `when` every program
// that imports Baldr would type-check the whole suite too. ODIN_TEST is set
// by `odin test`; BALDR_TESTS lets ./build.sh check look inside.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// Keeping the caret in view needs `caret_line`, which shapes the caret's
// whole paragraph, so revealing on every keystroke makes typing a message
// into a long paragraph O(n²). A run of typing leaves one reveal for the
// next layout instead (spikes/typing_cost measures it).
//
// Only typing coalesces. A click, an arrow, Ctrl+End or a paste still reveal
// inline: an app reading the scroll offset straight afterwards must see the
// move, and a wheel scroll in the same frame would fight a reveal that had
// not happened yet.

@(private = "file")
Ty_Msg :: union { int }

@(private = "file")
Ty_Fx :: struct {
	ui:  Ui(Ty_Msg),
	doc: Document,
	n:   Node,
}

@(private = "file")
ty_view :: proc(fx: ^Ty_Fx) {
	set_viewport(&fx.ui.tree, {400, 300})
	begin_view(&fx.ui)
	column(&fx.ui, padding = .lg)
	fx.n = text_area(&fx.ui, &fx.doc, label = "Composer", width = 300, height = 120)
	end(&fx.ui)
	end_view(&fx.ui)
	frame(&fx.ui.tree, {400, 300})
}

@(private = "file")
ty_start :: proc(fx: ^Ty_Fx, text: string) -> (Node, ^Text_Area_State) {
	ui_init(&fx.ui)
	fx.doc = document_make(text)
	ty_view(fx)
	set_focus(&fx.ui.tree, fx.n, true)
	ty_view(fx)
	return editor_area(&fx.ui.tree, fx.n)
}

// A run of typing leaves one reveal to do, not one per key.
@(test)
a_run_of_typing_asks_for_one_caret_reveal :: proc(t: ^testing.T) {
	fx: Ty_Fx
	long := strings.repeat("the quick brown fox jumps over the lazy dog. ", 40, context.temp_allocator)
	area, s := ty_start(&fx, long)
	defer { ui_destroy(&fx.ui); document_destroy(&fx.doc) }
	if s == nil do testing.fail_now(t, "no editor")
	area_move(&fx.ui.tree, area, s, Pos{0, len(long)}, false)
	ty_view(&fx)
	testing.expect(t, !s.reveal.pending, "nothing outstanding to start with")

	// thirty characters arriving together, as an input method's commit does
	for _ in 0 ..< 30 do text_area_text(&fx.ui, "x")
	testing.expect(t, s.typed_since_frame, "the run is in progress")
	testing.expect(t, s.reveal.pending, "the caret still has to be brought into view")
	testing.expect_value(t, s.reveal.pos, s.caret) // …at where it actually is now

	ty_view(&fx) // one layout settles it, however many keys there were
	testing.expect(t, !s.reveal.pending && !s.typed_since_frame, "and the next character starts afresh")
}

// The caret is still kept in view: the work moved, it did not go away.
@(test)
typing_past_the_bottom_still_scrolls_the_caret_into_view :: proc(t: ^testing.T) {
	fx: Ty_Fx
	area, s := ty_start(&fx, "first")
	defer { ui_destroy(&fx.ui); document_destroy(&fx.doc) }
	if s == nil do testing.fail_now(t, "no editor")
	st, has := &fx.ui.tree.scrolls[area]
	if !has do testing.fail_now(t, "the editor does not scroll")
	testing.expect_value(t, st.offset.y, 0)

	for _ in 0 ..< 40 {
		text_area_key(&fx.ui, .Enter, {})
		text_area_text(&fx.ui, "line")
	}
	ty_view(&fx)

	st2 := &fx.ui.tree.scrolls[area]
	testing.expect(t, st2.offset.y > 0, "the view followed the caret down")
	line, _, _ := caret_line(&fx.ui.tree, s, s.caret)
	lh := area_line_h(&fx.ui.tree, s, s.caret.block)
	cy := block_text_top(&fx.ui.tree, s, s.caret.block) + f32(line) * lh
	testing.expect(t, cy >= st2.offset.y - 1 && cy + lh <= st2.offset.y + st2.viewport.y + 1,
		"the caret's line is on screen")
}

// A caret move is not typing: it scrolls there and then, so an app that
// reads the offset straight after sees where it went.
@(test)
a_caret_move_still_reveals_at_once :: proc(t: ^testing.T) {
	fx: Ty_Fx
	area, s := ty_start(&fx, "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten")
	defer { ui_destroy(&fx.ui); document_destroy(&fx.doc) }
	if s == nil do testing.fail_now(t, "no editor")

	text_area_key(&fx.ui, .End, {.Ctrl}) // to the end of the document
	testing.expect(t, !s.typed_since_frame, "a caret move is not a typing run")
	testing.expect(t, fx.ui.tree.scrolls[area].offset.y > 0,
		"…so the view has already followed it, with no frame in between")

	text_area_key(&fx.ui, .Home, {.Ctrl})
	testing.expect_value(t, fx.ui.tree.scrolls[area].offset.y, 0)
}

}
