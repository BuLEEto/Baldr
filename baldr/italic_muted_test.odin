package baldr

@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too; behind this `when` an app does not pay for them.
// ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh check look
// inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// Two looks that say something without changing what a control does: an
// italic label (a tab that is only a preview), and a muted tree row (a file
// the project leaves out).

@(private = "file")
Im_Msg :: struct { kind: int, i: int, on: bool }

@(private = "file")
italic_view :: proc(ui: ^Ui(Im_Msg), italic: Maybe(bool)) -> (txt, btn: Node) {
	set_viewport(&ui.tree, {700, 200})
	begin_view(ui)
	row(ui, gap = .md)
	txt = text(ui, "Preview of a longer file name", italic = italic.? or_else false, key = 1)
	btn = button(ui, "main.odin", Im_Msg{kind = 1}, variant = .Ghost, key = 2)
	if v, said := italic.?; said do button_options(ui, btn, italic = v)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {700, 200})
	return
}

@(private = "file")
italic_texts :: proc(t: ^Tree) -> (italic, upright: int) {
	for c in draw_list(t) {
		dt, ok := c.(Draw_Text)
		if !ok do continue
		if dt.italic { italic += 1 } else { upright += 1 }
	}
	return
}

@(test)
a_text_and_a_buttons_label_can_be_italic :: proc(t: ^testing.T) {
	te: Text_Engine
	ui: Ui(Im_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	if !text_engine_init(&te) do testing.fail_now(t, "text_engine_init: the embedded fonts did not load")
	tree_use_text_engine(&ui.tree, &te)
	defer text_engine_destroy(&te)
	ui.tree.debug_bounds = true

	txt, btn := italic_view(&ui, true)
	it, up := italic_texts(&ui.tree)
	testing.expect(t, it == 2 && up == 0, "the text and the button's label are drawn in italics")
	// measured in the face it is drawn in, so its box holds what is drawn
	tk := node_get(&ui.tree, txt).kind.(Text_Kind)
	slanted := text_measure_as(&ui.tree, tk.str, tk.size, 0, tk.weight, family = tk.family, italic = true)
	upright := text_measure(&ui.tree, tk.str, tk.size, 0, tk.weight, family = tk.family)
	testing.expect_value(t, node_get(&ui.tree, txt).abs.w, slanted.x)
	testing.expectf(t, slanted.x != upright.x, "the italic face sets this line at another width (%v, %v), or the check above proves nothing", slanted.x, upright.x)
	testing.expect_value(t, len(ui.tree.bounds_faults), 0)
	testing.expect_value(t, node_get(&ui.tree, btn).access.name, "main.odin")

	// a button keeps it until told otherwise, as its other options are kept
	italic_view(&ui, nil)
	it, up = italic_texts(&ui.tree)
	testing.expect(t, it == 1 && up == 1, "the button stays italic; the text, built without it, does not")

	// and taking it off applies in the same build
	italic_view(&ui, false)
	it, up = italic_texts(&ui.tree)
	testing.expect(t, it == 0 && up == 2, "both upright again")
	testing.expect_value(t, len(ui.tree.bounds_faults), 0)
}

@(private = "file")
muted_view :: proc(ui: ^Ui(Im_Msg), sel: int) -> (tree: Node) {
	set_viewport(&ui.tree, {300, 300})
	begin_view(ui)
	column(ui)
	tree = tree_view(ui, label = "Project", flex = 1)
	tree_item(ui, "src", Im_Msg{kind = 1, i = 1}, selected = sel == 1, icon = .Folder, key = 1)
	tree_item(ui, "build", Im_Msg{kind = 1, i = 2}, on_change = proc(e: Ev(bool)) -> Im_Msg { return {kind = 2, i = int(e.tag), on = e.value} },
		selected = sel == 2, icon = .Folder, muted = true, tag = 2, key = 2)
	tree_item(ui, "out.log", Im_Msg{kind = 1, i = 3}, selected = sel == 3, icon = .File, muted = true, key = 3)
	end(ui)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {300, 300})
	return
}

@(private = "file")
muted_inks :: proc(t: ^Tree, label: string) -> (text, icon: Color) {
	cmds := draw_list(t)
	for c, i in cmds {
		dt, ok := c.(Draw_Text)
		if !ok || dt.str != label do continue
		text = dt.color
		for j := i - 1; j >= 0; j -= 1 { // the row's icon comes before its label
			if ic, is_icon := cmds[j].(Draw_Icon); is_icon {
				icon = ic.color
				break
			}
		}
	}
	return
}

@(test)
a_muted_tree_row_looks_quieter_and_still_works :: proc(t: ^testing.T) {
	ui: Ui(Im_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	tree := muted_view(&ui, 0)
	lk := tree_row_look(&ui.tree.theme)
	testing.expect(t, lk.muted_ink != lk.ink, "the theme's muted ink differs, or this proves nothing")

	tx, ic := muted_inks(&ui.tree, "src")
	testing.expect(t, tx == lk.ink && ic == lk.ink, "an ordinary row")
	tx, ic = muted_inks(&ui.tree, "build")
	testing.expect(t, tx == lk.muted_ink && ic == lk.muted_ink, "a muted branch: its label and icon both, not the branch's accent")
	tx, ic = muted_inks(&ui.tree, "out.log")
	testing.expect(t, tx == lk.muted_ink && ic == lk.muted_ink, "a muted leaf")

	rows := tree_rows_in_order(&ui.tree, tree)
	testing.expect_value(t, len(rows), 3)
	for r in rows[1:] {
		d := node_get(&ui.tree, r)
		testing.expect(t, .Disabled not_in d.flags && .Disabled not_in d.access.states, "muted is not disabled")
	}
	// it is clicked and opened like any other row
	ui.tree.now_ms = 1000
	r := node_get(&ui.tree, rows[2]).abs
	p := [2]f32{r.x + r.w / 2, r.y + r.h / 2}
	pointer_button(&ui, .Left, true, p)
	pointer_button(&ui, .Left, false, p)
	testing.expect(t, len(ui.msgs) == 1 && ui.msgs[0] == Im_Msg{kind = 1, i = 3}, "a click on a muted row picks it")
	clear(&ui.msgs)
	chev := node_get(&ui.tree, ui.tree.tree_rows[rows[1]].chevron).abs
	cp := [2]f32{chev.x + chev.w / 2, chev.y + chev.h / 2}
	ui.tree.now_ms = 3000
	pointer_button(&ui, .Left, true, cp)
	pointer_button(&ui, .Left, false, cp)
	testing.expect(t, len(ui.msgs) == 1 && ui.msgs[0] == Im_Msg{kind = 2, i = 2, on = true}, "a muted branch opens")
	clear(&ui.msgs)

	// selected, it takes the ink made to read on the selection
	muted_view(&ui, 3)
	tx, ic = muted_inks(&ui.tree, "out.log")
	testing.expect(t, tx == lk.selected_ink && ic == lk.selected_ink, "a selected muted row reads as selected")
}

} // when ODIN_TEST
