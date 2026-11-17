package baldr

@(require) import "core:fmt"
@(require) import "core:testing"

// Telling a click on a row from arriving at it. `on_select` fires for every
// change of selection (a click, every Up or Down, a marquee, type-ahead) and
// cannot tell them apart, so "one click opens a row's details" built on it
// would open one per arrow key and one on the first click of a Ctrl- or
// Shift- multi-select. `on_click` is the gesture itself.
//
// Test files are part of the package, so everything that imports Baldr
// type-checks them too; behind this `when` an app does not pay for them.
when ODIN_TEST || #config(BALDR_TESTS, false) {

@(private = "file")
Rc_Kind :: enum u8 { None, Selected, Clicked, Activated }

@(private = "file")
Rc_Msg :: struct {
	kind: Rc_Kind,
	i:    int,
}

@(private = "file")
RC_COLS := []Column{{title = "Name"}, {title = "Size", width = 80}}

@(private = "file")
rc_view :: proc(ui: ^Ui(Rc_Msg), sel: ^Selection) -> Node {
	set_viewport(&ui.tree, {600, 400})
	begin_view(ui)
	column(ui, flex = 1)
	first, last := table(ui, RC_COLS, 500, sel,
		on_select = proc(e: Ev(int)) -> Rc_Msg { return {kind = .Selected, i = e.value} },
		on_click = proc(e: Ev(int)) -> Rc_Msg { return {kind = .Clicked, i = e.value} },
		on_activate = proc(e: Ev(int)) -> Rc_Msg { return {kind = .Activated, i = e.value} },
		label = "Files", key = 1)
	for i in first ..< last {
		table_row(ui, i)
		cell_text(ui, fmt.tprintf("file-%05d", i))
		cell_text(ui, fmt.tprintf("%d KB", i * 3))
		end(ui)
	}
	end(ui)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {600, 400})
	return node_first(&ui.tree, node_first(&ui.tree, ui.root))
}

@(private = "file")
rc_settled :: proc(ui: ^Ui(Rc_Msg), sel: ^Selection) -> Node {
	tbl := rc_view(ui, sel)
	for _ in 0 ..< 3 {
		ui.needs_rebuild = false
		ui_after_events(ui, 1)
		if !ui.needs_rebuild do break
		ui.needs_rebuild = false
		tbl = rc_view(ui, sel)
	}
	return tbl
}

@(private = "file")
rc_row :: proc(ui: ^Ui(Rc_Msg), tbl: Node, index: int) -> Node {
	ts := ui.tree.tables[tbl]
	for n, ref in ui.rows do if ref.table == tbl && ref.index == index do return n
	_ = ts
	return NODE_NONE
}

@(private = "file")
rc_click :: proc(ui: ^Ui(Rc_Msg), tbl: Node, index: int, mods: Mods, now: f64) {
	r := node_get(&ui.tree, rc_row(ui, tbl, index)).abs
	p := [2]f32{r.x + 20, r.y + r.h / 2}
	ui.tree.now_ms = now
	ui.pointer.mods = mods
	pointer_button(ui, .Left, true, p)
	pointer_button(ui, .Left, false, p)
}

// rc_kinds is which messages of each kind arrived since `from`.
@(private = "file")
rc_kinds :: proc(ui: ^Ui(Rc_Msg), from: int, kind: Rc_Kind) -> (n: int, last: int) {
	last = -1
	for m in ui.msgs[from:] do if m.kind == kind {
		n += 1
		last = m.i
	}
	return
}

@(test)
a_row_click_is_told_apart_from_walking_to_the_row :: proc(t: ^testing.T) {
	ui: Ui(Rc_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	sel := selection_make(multi = true)
	defer selection_destroy(&sel)
	tbl := rc_settled(&ui, &sel)

	// A plain click: both, because the selection really did change and the
	// row really was clicked.
	from := len(ui.msgs)
	rc_click(&ui, tbl, 2, {}, 1000)
	sel_n, _ := rc_kinds(&ui, from, .Selected)
	click_n, click_i := rc_kinds(&ui, from, .Clicked)
	testing.expect_value(t, sel_n, 1)
	testing.expect_value(t, click_n, 1)
	testing.expect_value(t, click_i, 2)

	// Walking with the arrows selects and does not click, however far you
	// walk.
	set_focus(&ui.tree, tbl, true)
	from = len(ui.msgs)
	for _ in 0 ..< 4 do testing.expect(t, key_event(&ui, .Down, true, {}))
	testing.expect(t, key_event(&ui, .Up, true, {}))
	sel_n, _ = rc_kinds(&ui, from, .Selected)
	click_n, _ = rc_kinds(&ui, from, .Clicked)
	testing.expectf(t, sel_n == 5, "five keys, five selections (%d)", sel_n)
	testing.expectf(t, click_n == 0, "and not one click (%d)", click_n)

	// Building a selection is not choosing a row either: a Ctrl- or Shift-
	// click is on its way somewhere, so it does not click.
	from = len(ui.msgs)
	rc_click(&ui, tbl, 5, {.Ctrl}, 2000)
	rc_click(&ui, tbl, 7, {.Shift}, 3000)
	click_n, _ = rc_kinds(&ui, from, .Clicked)
	testing.expectf(t, click_n == 0, "ctrl- and shift-click do not click (%d)", click_n)
	sel_n, _ = rc_kinds(&ui, from, .Selected)
	testing.expect_value(t, sel_n, 2)

	// A double-click is on_activate's. The first of the two is a real click
	// and says so; the second is not another one.
	from = len(ui.msgs)
	rc_click(&ui, tbl, 1, {}, 5000)
	rc_click(&ui, tbl, 1, {}, 5100)
	click_n, _ = rc_kinds(&ui, from, .Clicked)
	act_n, act_i := rc_kinds(&ui, from, .Activated)
	testing.expectf(t, click_n == 1, "the first click of a double is a click, the second is not (%d)", click_n)
	testing.expectf(t, act_n == 1 && act_i == 1, "and the double activated (%d, row %d)", act_n, act_i)
}

// A table given no on_click still sends on_select for a click, and no
// click message.
@(test)
a_table_without_on_click_is_unchanged :: proc(t: ^testing.T) {
	ui: Ui(Rc_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	sel := selection_make(multi = true)
	defer selection_destroy(&sel)
	view :: proc(ui: ^Ui(Rc_Msg), sel: ^Selection) -> Node {
		set_viewport(&ui.tree, {600, 400})
		begin_view(ui)
		column(ui, flex = 1)
		first, last := table(ui, RC_COLS, 500, sel,
			on_select = proc(e: Ev(int)) -> Rc_Msg { return {kind = .Selected, i = e.value} },
			label = "Files", key = 1)
		for i in first ..< last {
			table_row(ui, i)
			cell_text(ui, fmt.tprintf("file-%05d", i))
			cell_text(ui, fmt.tprintf("%d KB", i * 3))
			end(ui)
		}
		end(ui)
		end(ui)
		end_view(ui)
		frame(&ui.tree, {600, 400})
		return node_first(&ui.tree, node_first(&ui.tree, ui.root))
	}
	tbl := view(&ui, &sel)
	for _ in 0 ..< 3 {
		ui.needs_rebuild = false
		ui_after_events(&ui, 1)
		if !ui.needs_rebuild do break
		ui.needs_rebuild = false
		tbl = view(&ui, &sel)
	}
	from := len(ui.msgs)
	rc_click(&ui, tbl, 3, {}, 1000)
	sel_n, sel_i := rc_kinds(&ui, from, .Selected)
	click_n, _ := rc_kinds(&ui, from, .Clicked)
	testing.expect_value(t, sel_n, 1)
	testing.expect_value(t, sel_i, 3)
	testing.expectf(t, click_n == 0, "no on_click was given, so none is sent (%d)", click_n)
}

}
