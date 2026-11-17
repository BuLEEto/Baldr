package baldr

@(require) import "core:fmt"
@(require) import "core:testing"

// Test files are part of the package, so without this `when` every program
// that imports Baldr would type-check the whole suite too. ODIN_TEST is set
// by `odin test`; BALDR_TESTS lets ./build.sh check look inside.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// A control built in a table cell takes its own click, as it does anywhere
// else: a ▸ before each row's name, a toggle in another column.


@(private = "file")
Tc_Msg :: union { Tc_Open, Tc_Pick, Tc_Keep }
@(private = "file") Tc_Open :: struct { i: int }
@(private = "file") Tc_Pick :: struct { i: int }
@(private = "file") Tc_Keep :: struct { on: bool }

@(private = "file")
keep :: proc(e: Ev(bool)) -> Tc_Msg { return Tc_Keep{e.value} }

@(private = "file")
TC_COLS := []Column{{title = "Name"}, {title = "Keep", width = 80}}

@(private = "file")
apps :: proc(ui: ^Ui(Tc_Msg), sel: ^Selection) -> (opens, keeps: [dynamic]Node, tbl: Node) {
	opens = make([dynamic]Node, context.temp_allocator)
	keeps = make([dynamic]Node, context.temp_allocator)
	set_viewport(&ui.tree, {600, 400})
	begin_view(ui)
	column(ui, flex = 1)
	first, last := table(ui, TC_COLS, 20, sel, on_select = proc(e: Ev(int)) -> Tc_Msg { return Tc_Pick{e.value} }, label = "Apps", key = 3)
	for i in first ..< last {
		table_row(ui, i)
		cell(ui)
		append(&opens, button(ui, "Open", Tc_Msg(Tc_Open{i}), icon = .Chevron_Right, icon_only = true, size = .Small, variant = .Ghost, key = u64(i + 1)))
		text(ui, fmt.tprintf("app-%d", i))
		end(ui)
		cell(ui)
		append(&keeps, toggle(ui, false, "Keep", on_change = keep, key = u64(i + 100)))
		end(ui)
		end(ui)
	}
	end(ui)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {600, 400})
	tbl = node_first(&ui.tree, node_first(&ui.tree, ui.root))
	return
}

@(private = "file")
tc_click :: proc(ui: ^Ui(Tc_Msg), p: [2]f32, now: f64) {
	ui.tree.now_ms = now
	pointer_move(ui, p)
	pointer_button(ui, .Left, true, p)
	pointer_button(ui, .Left, false, p)
}

@(test)
a_control_in_a_table_cell_takes_its_own_click :: proc(t: ^testing.T) {
	ui: Ui(Tc_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	sel := selection_make(multi = true)
	defer selection_destroy(&sel)
	opens, keeps, tbl := apps(&ui, &sel)
	for _ in 0 ..< 2 {
		ui.needs_rebuild = false
		ui_after_events(&ui, 1)
		opens, keeps, tbl = apps(&ui, &sel)
	}
	if len(opens) < 4 || len(keeps) < 4 do testing.fail_now(t, "fixture: rows were built")

	bd := node_get(&ui.tree, opens[2]).abs
	tc_click(&ui, {bd.x + bd.w / 2, bd.y + bd.h / 2}, 1000)
	opened := -1
	for m in ui.msgs do if o, ok := m.(Tc_Open); ok do opened = o.i
	testing.expect_value(t, opened, 2) // the ▸ was clicked
	testing.expect(t, !ui.tree.tables[tbl].grid.marquee, "no band from a press on a control")

	clear(&ui.msgs)
	kd := node_get(&ui.tree, keeps[1]).abs
	tc_click(&ui, {kd.x + kd.w / 2, kd.y + kd.h / 2}, 3000)
	kept := false
	for m in ui.msgs do if k, ok := m.(Tc_Keep); ok do kept = k.on
	testing.expect(t, kept, "the toggle in the other cell flipped")

	clear(&ui.msgs) // the row's own text still selects it
	td := node_get(&ui.tree, opens[3]).abs
	tc_click(&ui, {td.x + td.w + 30, td.y + td.h / 2}, 5000)
	testing.expect(t, selection_contains(&sel, 3), "a press on the row's text picks the row")
}

} // when ODIN_TEST