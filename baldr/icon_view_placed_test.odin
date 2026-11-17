package baldr

@(require) import "core:fmt"
@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: behind this `when`, checking a program costs
// 1.0 GB instead of 9.2 GB. ODIN_TEST is set by `odin test`; BALDR_TESTS
// lets ./build.sh check look inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// Placed mode: the app says which cell each item goes in and the view keeps
// nothing, the same bargain it makes with the selection.

@(private = "file")
Ivp_Kind :: enum { None, Place, Pick }

@(private = "file")
Ivp_Msg :: struct {
	kind:  Ivp_Kind,
	n:     int,
	items: [8]int,
	cells: [8][2]int,
	cell:  [2]int,
	item:  int,
	i:     int,
}

@(private = "file")
Ivp_Places :: [8][2]int

@(private = "file")
ivp_place_of :: proc(user: rawptr, index: int) -> [2]int {
	places := (^Ivp_Places)(user)
	if index < 0 || index >= len(places) do return {-1, -1}
	return places[index]
}

// the desktop this exercises: four items the app placed (two of them asking
// for the same cell) and four it never placed, which flow down the columns
@(private = "file")
IVP_ASKED :: Ivp_Places{{0, 0}, {2, 1}, {1, 0}, {2, 1}, {-1, -1}, {-1, -1}, {-1, -1}, {-1, -1}}
@(private = "file")
IVP_GOT :: Ivp_Places{{0, 0}, {2, 1}, {1, 0}, {2, 0}, {0, 1}, {0, 2}, {1, 1}, {1, 2}}

@(private = "file")
ivp_view :: proc(ui: ^Ui(Ivp_Msg), sel: ^Selection, places: ^Ivp_Places) -> Node {
	set_viewport(&ui.tree, {600, 400})
	begin_view(ui)
	column(ui, flex = 1)
	first, last := icon_view(ui, 8, sel,
		place_of = ivp_place_of, place_user = places,
		on_place = proc(e: Ev(Place_Drop)) -> Ivp_Msg {
			m := Ivp_Msg{kind = .Place, n = len(e.value.items), cell = e.value.cell, item = e.value.item}
			for it, k in e.value.items {
				m.items[k] = it
				m.cells[k] = e.value.cells[k]
			}
			return m
		},
		on_select = proc(e: Ev(int)) -> Ivp_Msg { return {kind = .Pick, i = e.value} },
		drag = "files", accepts = "files", label = "Desktop", key = 7)
	for i in first ..< last do icon_item(ui, i, .File, fmt.tprintf("item-%d", i))
	end(ui)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {600, 400})
	return node_first(&ui.tree, node_first(&ui.tree, ui.root))
}

@(private = "file")
ivp_settled :: proc(ui: ^Ui(Ivp_Msg), sel: ^Selection, places: ^Ivp_Places) -> Node {
	v := ivp_view(ui, sel, places)
	for _ in 0 ..< 3 {
		ui.needs_rebuild = false
		ui_after_events(ui, ui.tree.now_ms + 1)
		v = ivp_view(ui, sel, places)
	}
	return v
}

@(private = "file")
ivp_tile :: proc(ui: ^Ui(Ivp_Msg), view: Node, index: int) -> Node {
	for n, ref in ui.rows do if ref.table == view && ref.index == index && node_valid(&ui.tree, n) do return n
	return NODE_NONE
}

// the window point at the middle of cell `c`
@(private = "file")
ivp_at :: proc(ui: ^Ui(Ivp_Msg), view: Node, c: [2]int) -> [2]f32 {
	vs := &ui.tree.icon_views[view]
	sd := node_get(&ui.tree, vs.stack)
	pitch := icon_view_pitch(vs)
	return {sd.abs.x + f32(c.x) * pitch.x + vs.tile.x / 2, sd.abs.y + f32(c.y) * pitch.y + vs.tile.y / 2}
}

@(private = "file")
ivp_click :: proc(ui: ^Ui(Ivp_Msg), view: Node, index: int, mods: Mods, now: f64) {
	r := node_get(&ui.tree, ivp_tile(ui, view, index)).abs
	p := [2]f32{r.x + 10, r.y + 10}
	ui.tree.now_ms = now
	ui.pointer.mods = mods
	pointer_button(ui, .Left, true, p)
	pointer_button(ui, .Left, false, p)
	ui.pointer.mods = {}
}

// a drag of the tile showing `index`, released over cell `to`
@(private = "file")
ivp_drag :: proc(ui: ^Ui(Ivp_Msg), view: Node, index: int, to: [2]int) {
	r := node_get(&ui.tree, ivp_tile(ui, view, index)).abs
	p := [2]f32{r.x + 10, r.y + 10}
	pointer_button(ui, .Left, true, p)
	pointer_move(ui, p + {14, 0})
	target := ivp_at(ui, view, to)
	pointer_move(ui, target)
	pointer_button(ui, .Left, false, target)
}

@(test)
icon_view_placed_puts_each_item_where_the_app_said :: proc(t: ^testing.T) {
	ui: Ui(Ivp_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	sel := selection_make(multi = true)
	defer selection_destroy(&sel)
	places := IVP_ASKED
	view := ivp_settled(&ui, &sel, &places)
	vd := node_get(&ui.tree, view)
	testing.expect_value(t, vd.access.role, Role.List)
	testing.expect_value(t, vd.access.name, "Desktop")
	vs := &ui.tree.icon_views[view]
	testing.expect(t, vs.placed)
	want := IVP_GOT
	for i in 0 ..< 8 {
		testing.expectf(t, vs.cells[i] == want[i], "item %d landed on %v, wanted %v", i, vs.cells[i], want[i])
	}
	testing.expect_value(t, vs.rows_used, 3)
	// every tile is drawn at its cell, on the shared pitch
	pitch := icon_view_pitch(vs)
	origin := node_get(&ui.tree, ivp_tile(&ui, view, 0)).abs
	for i in 1 ..< 8 {
		td := node_get(&ui.tree, ivp_tile(&ui, view, i))
		testing.expectf(t, abs(td.abs.x - (origin.x + f32(want[i].x) * pitch.x)) < 0.5 &&
			abs(td.abs.y - (origin.y + f32(want[i].y) * pitch.y)) < 0.5,
			"item %d drawn at %v,%v", i, td.abs.x, td.abs.y)
		testing.expect_value(t, td.access.role, Role.List_Item)
		testing.expect_value(t, td.access.name, fmt.tprintf("item-%d", i))
	}
	testing.expect_value(t, len(ui.tree.diags), 0) // scopes balanced: end() closed stack, scroll and view
	testing.expect(t, lint(&ui.tree) == 0)
	// an item placed far down the column is not built at all
	places[7] = {0, 30}
	view = ivp_settled(&ui, &sel, &places)
	vs = &ui.tree.icon_views[view]
	testing.expect_value(t, vs.rows_used, 31)
	testing.expect_value(t, vs.cells[7], [2]int{0, 30})
	testing.expect(t, ivp_tile(&ui, view, 7) == NODE_NONE, "off-screen rows cost nothing")
	testing.expect(t, ivp_tile(&ui, view, 0) != NODE_NONE)
}

@(test)
icon_view_placed_arrows_move_by_geometry :: proc(t: ^testing.T) {
	ui: Ui(Ivp_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	sel := selection_make(multi = true)
	defer selection_destroy(&sel)
	places := IVP_ASKED
	view := ivp_settled(&ui, &sel, &places)
	ivp_click(&ui, view, 0, {}, 1000)
	testing.expect_value(t, sel.cursor, 0)
	testing.expect_value(t, ui.tree.focus, view)
	Step :: struct { key: Key, to: int }
	// the nearest item that way, which is nothing like the index order
	for step in ([]Step{{.Right, 2}, {.Right, 3}, {.Down, 1}, {.Left, 6}, {.Up, 2}, {.Left, 0}, {.Down, 4}, {.Down, 5}}) {
		testing.expect(t, key_event(&ui, step.key, true, {}))
		testing.expectf(t, sel.cursor == step.to, "%v went to %d, wanted %d", step.key, sel.cursor, step.to)
	}
	// nothing below or left of the bottom of the first column: the cursor stays
	testing.expect(t, key_event(&ui, .Down, true, {}))
	testing.expect_value(t, sel.cursor, 5)
	testing.expect(t, key_event(&ui, .Left, true, {}))
	testing.expect_value(t, sel.cursor, 5)
	// Shift extends over the geometry step, as it does in the flow
	testing.expect(t, key_event(&ui, .Up, true, {.Shift}))
	testing.expect_value(t, sel.cursor, 4)
	testing.expect(t, selection_contains(&sel, 4) && selection_contains(&sel, 5))
	// Home and End are the ends of the reading order: down the columns
	testing.expect(t, key_event(&ui, .Home, true, {}))
	testing.expect_value(t, sel.cursor, 0)
	testing.expect(t, key_event(&ui, .End, true, {}))
	testing.expect_value(t, sel.cursor, 1) // {2, 1}: the last cell in use
	testing.expect(t, key_event(&ui, .A, true, {.Ctrl}))
	testing.expect_value(t, selection_count(&sel), 8)
}

@(test)
icon_view_placed_drop_reports_the_cells_it_landed_on :: proc(t: ^testing.T) {
	ui: Ui(Ivp_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	sel := selection_make(multi = true)
	defer selection_destroy(&sel)
	places := IVP_ASKED
	view := ivp_settled(&ui, &sel, &places)
	// one item onto a cell another item holds: it steps aside, it does not vanish
	ivp_click(&ui, view, 5, {}, 1000)
	clear(&ui.msgs)
	ivp_drag(&ui, view, 5, {2, 0})
	placed := Ivp_Msg{}
	for m in ui.msgs do if m.kind == .Place do placed = m
	testing.expect_value(t, placed.kind, Ivp_Kind.Place)
	testing.expect_value(t, placed.n, 1)
	testing.expect_value(t, placed.item, 5)
	testing.expect_value(t, placed.cell, [2]int{2, 0}) // the raw cell, for an app that would rather sort it out itself
	testing.expect_value(t, placed.items[0], 5)
	testing.expect_value(t, placed.cells[0], [2]int{3, 0}) // {2, 0} is item 3's: the nearest free one
	testing.expect_value(t, ui.tree.icon_views[view].cells[5], [2]int{0, 2}) // the view moved nothing itself
	// a selection moves whole and keeps its shape
	view = ivp_settled(&ui, &sel, &places)
	ivp_click(&ui, view, 0, {}, 2000)
	ivp_click(&ui, view, 4, {.Ctrl}, 2200)
	testing.expect_value(t, selection_count(&sel), 2)
	clear(&ui.msgs)
	ivp_drag(&ui, view, 0, {2, 2})
	placed = {}
	for m in ui.msgs do if m.kind == .Place do placed = m
	testing.expect_value(t, placed.n, 2)
	testing.expect_value(t, placed.item, 0)
	testing.expect_value(t, placed.items[0], 0)
	testing.expect_value(t, placed.cells[0], [2]int{2, 2}) // the one under the pointer lands on the drop cell
	testing.expect_value(t, placed.items[1], 4)
	testing.expect_value(t, placed.cells[1], [2]int{2, 3}) // …and the other keeps its offset from it
	// the app writes it down and hands it back: that is the whole of placement
	places[0], places[4] = placed.cells[0], placed.cells[1]
	view = ivp_settled(&ui, &sel, &places)
	testing.expect_value(t, ui.tree.icon_views[view].cells[0], [2]int{2, 2})
	testing.expect_value(t, ui.tree.icon_views[view].cells[4], [2]int{2, 3})
}

@(test)
icon_view_placed_band_selects_whoever_is_in_the_cell :: proc(t: ^testing.T) {
	ui: Ui(Ivp_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	sel := selection_make(multi = true)
	defer selection_destroy(&sel)
	places := IVP_ASKED
	view := ivp_settled(&ui, &sel, &places)
	vs := &ui.tree.icon_views[view]
	pitch := icon_view_pitch(vs)
	sd := node_get(&ui.tree, vs.stack)
	start := [2]f32{sd.abs.x + 6, sd.abs.y + 3 * pitch.y + 10} // empty ground below the first column
	pointer_move(&ui, start)
	testing.expect(t, !(ui.pointer.hover in ui.rows), "the band starts on empty space")
	pointer_button(&ui, .Left, true, start)
	testing.expect_value(t, ui.marquee, view)
	up := ivp_at(&ui, view, {0, 0})
	pointer_move(&ui, up)
	// the first column holds 0, 4 and 5 — index arithmetic would have said 0 and 5
	testing.expect_value(t, selection_count(&sel), 3)
	testing.expect(t, selection_contains(&sel, 0) && selection_contains(&sel, 4) && selection_contains(&sel, 5))
	pointer_button(&ui, .Left, false, up)
	testing.expect_value(t, ui.marquee, NODE_NONE)
	testing.expect_value(t, selection_count(&sel), 3)
}

} // when ODIN_TEST