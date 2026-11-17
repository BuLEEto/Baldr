package baldr

@(require) import "core:strings"
@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too; behind this `when` an app does not pay for them.
// ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh check look
// inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// A launcher's results: rows a search field walks, the pointer resting on a
// row, a field's active item, and a surface that is only a scrim.


@(private = "file")
Rest :: struct { i: int, on: bool }

@(private = "file")
ResultRows_LMsg :: union { int, Rest }

@(private = "file")
Found :: struct { title: string, icon: Icon, theme_icon, glyph, detail, hint: string, variant: Row_Variant, size: Row_Size }

@(private = "file")
LAUNCHER := [4]Found{
	{title = "Firefox", theme_icon = "firefox", detail = "Web browser", hint = "↵ open", variant = .Tile},
	{title = "Settings", icon = .Settings, detail = "System", hint = "↵ open", variant = .Tile},
	{title = "Grinning face", glyph = "😀", detail = "Emoji", hint = "↵ copy", variant = .Tile},
	{title = "42", icon = .Check, detail = "6 × 7", hint = "↵ copy", variant = .Accent, size = .Large},
}

// results: a search field (focusable, named Search) over the launcher's rows, `current` selected, row `gone` left out.
@(private = "file")
results :: proc(ui: ^Ui(ResultRows_LMsg), current: int, gone := -1) -> (field: Node, rows: [4]Node) {
	begin_view(ui)
	column(ui, width = 480, padding = .sm, gap = .xs)
	field = row(ui, height = 40, key = 99)
	fd := node_get(&ui.tree, field)
	fd.flags += {.Focusable}
	set_role(&ui.tree, field, .Search_Box)
	set_name(&ui.tree, field, "Search")
	end(ui)
	found := LAUNCHER
	for f, i in found {
		if i == gone do continue
		r := list_row(ui, f.title, ResultRows_LMsg(i), icon = f.icon, theme_icon = f.theme_icon, glyph = f.glyph, detail = f.detail,
			selected = i == current, hint = f.hint, variant = f.variant, size = f.size, on_context = ResultRows_LMsg(100 + i), tag = u64(i), key = u64(i + 1))
		hoverable(ui, r, proc(e: Ev(bool)) -> ResultRows_LMsg { return Rest{int(e.tag), e.value} })
		rows[i] = r
	}
	end(ui)
	end_view(ui)
	frame(&ui.tree, {500, 400})
	return
}

@(private = "file")
part :: proc(t: ^Tree, n: Node, p: Control_Part) -> Node {
	for c := node_get(t, n).first; c != NODE_NONE; c = node_get(t, c).next do if Control_Part(node_get(t, c).key) == p do return c
	return NODE_NONE
}

@(private = "file")
title_of :: proc(t: ^Tree, row: Node) -> ^Text_Kind {
	words := node_get(t, part(t, row, .Label))
	return &node_get(t, words.first).kind.(Text_Kind)
}

// A tiled row puts its icon in a 36 px tile before its words: an app's own
// icon fills it, a Lucide icon sits on a quiet tile with an edge, a glyph on
// a quiet tile, and an accent tile is tinted with the accent, its icon in it.
// Its title is 14 px medium over a 12.5 px detail; a large one is 23 px
// semibold; the row is its tile and 9 px above and below.
@(test)
tiled_rows_show_a_launchers_results :: proc(t: ^testing.T) {
	ui: Ui(ResultRows_LMsg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	_, r := results(&ui, -1)
	tr := &ui.tree
	th := &tr.theme
	for row in r {
		tile := node_get(tr, part(tr, row, .Tile))
		testing.expect(t, tile != nil, "every tiled row has its tile")
		if tile == nil do continue
		testing.expect_value(t, [2]f32{tile.abs.w, tile.abs.h}, [2]f32{LIST_ROW_TILE, LIST_ROW_TILE})
		testing.expect_value(t, tile.style.radius, LIST_ROW_TILE_RADIUS)
		testing.expect(t, tile.abs.x < node_get(tr, part(tr, row, .Label)).abs.x, "the tile before the words")
	}
	app := node_get(tr, part(tr, r[0], .Tile))
	testing.expect_value(t, app.style.bg, Color{}) // an app's icon fills it
	icon := node_get(tr, part(tr, part(tr, r[0], .Tile), .Theme_Icon))
	testing.expect(t, icon != nil && icon.kind.(Custom_Kind).size == {LIST_ROW_TILE_APP_ICON, LIST_ROW_TILE_APP_ICON}, "the app's icon at 32 px")
	testing.expect_value(t, node_get(tr, r[0]).abs.h, LIST_ROW_TILE + 18)

	quiet := node_get(tr, part(tr, r[1], .Tile))
	testing.expect(t, quiet.style.bg == th.color.fill && quiet.style.border_w == 1 && quiet.style.border == th.color.outline_variant, "a quiet tile with an edge")
	testing.expect_value(t, node_get(tr, part(tr, part(tr, r[1], .Tile), .Icon)).style.fg, th.color.on_surface_muted)

	emoji := node_get(tr, part(tr, r[2], .Tile))
	testing.expect(t, emoji.style.bg == th.color.fill && emoji.style.border_w == 0, "a glyph on a quiet tile")
	g := node_get(tr, emoji.first)
	testing.expect(t, g != nil && g.kind.(Text_Kind).str == "😀" && g.kind.(Text_Kind).size == LIST_ROW_TILE_GLYPH, "the glyph at 22 px")

	accent := node_get(tr, part(tr, r[3], .Tile))
	testing.expect_value(t, accent.style.bg, with_alpha(th.color.primary, LIST_ROW_ACCENT_TILE))
	testing.expect_value(t, node_get(tr, part(tr, part(tr, r[3], .Tile), .Icon)).style.fg, th.color.primary)

	ft := title_of(tr, r[0])
	testing.expect(t, ft.size == LIST_ROW_TITLE && ft.weight == .Medium, "a 14 px medium title")
	lt := title_of(tr, r[3])
	testing.expect(t, lt.size == LIST_ROW_TITLE_LARGE && lt.weight == .Semibold, "a large one: 23 px semibold")
	words := node_get(tr, part(tr, r[0], .Label))
	detail := node_get(tr, node_get(tr, words.first).next)
	testing.expect(t, detail != nil && detail.kind.(Text_Kind).size == LIST_ROW_DETAIL, "a 12.5 px detail under it")
}

// A selected row has the accent behind it and a 3 px bar inside its start,
// inset 9 px from its top and bottom, and its hint at its end: the key in a
// cap and what it does. It is Selected for assistive technology, and focus
// stays in the field. Selecting another moves all of that.
@(test)
a_selected_row_says_so_and_leaves_focus_alone :: proc(t: ^testing.T) {
	ui: Ui(ResultRows_LMsg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	field, r := results(&ui, -1)
	tr := &ui.tree
	th := &tr.theme
	set_focus(tr, field, false)
	_, r = results(&ui, 1)
	testing.expect_value(t, tr.focus, field) // the field keeps focus
	sd := node_get(tr, r[1])
	testing.expect(t, .Selected in sd.access.states, "announced as selected")
	testing.expect_value(t, sd.style.bg, with_alpha(th.color.primary, LIST_ROW_SELECTED))
	bar := tr.button_marks[r[1]].mark
	testing.expect_value(t, bar, Button_Mark{side = .Left, length = sd.abs.h - 2 * LIST_ROW_BAR_INSET, thickness = LIST_ROW_BAR, color = th.color.primary})
	hint := part(tr, r[1], .Hint)
	testing.expect(t, hint != NODE_NONE, "its hint shows")
	if hint != NODE_NONE {
		cap := node_get(tr, node_get(tr, hint).first)
		testing.expect_value(t, node_get(tr, cap.first).kind.(Text_Kind).str, "↵")
		testing.expect_value(t, node_get(tr, cap.next).kind.(Text_Kind).str, "open")
		testing.expect(t, node_get(tr, hint).abs.x > node_get(tr, part(tr, r[1], .Label)).abs.x, "at the row's end")
	}
	testing.expect(t, part(tr, r[0], .Hint) == NODE_NONE && .Selected not_in node_get(tr, r[0]).access.states, "the others show no hint")
	testing.expect_value(t, lint(tr), 0)

	_, r = results(&ui, 2)
	testing.expect(t, .Selected not_in node_get(tr, r[1]).access.states && part(tr, r[1], .Hint) == NODE_NONE, "the one before is plain again")
	testing.expect_value(t, tr.button_marks[r[1]].mark.length, 0)
	testing.expect_value(t, node_get(tr, r[1]).style.bg, Color{})
	testing.expect(t, .Selected in node_get(tr, r[2]).access.states && part(tr, r[2], .Hint) != NODE_NONE, "the next is selected")
}

// A right-click on a row sends its context message. The pointer resting on a
// row makes the row hear true once, and false when the pointer moves to
// another row or leaves the surface; moving within it sends nothing, and
// neither does the list changing under a still pointer. A row that goes
// away while the pointer rests on it hears false.
@(test)
a_row_hears_its_menu_and_the_pointer_resting_on_it :: proc(t: ^testing.T) {
	ui: Ui(ResultRows_LMsg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	_, r := results(&ui, 0)
	tr := &ui.tree
	at :: proc(tr: ^Tree, n: Node, dx: f32 = 0) -> [2]f32 { d := node_get(tr, n); return {d.abs.x + 80 + dx, d.abs.y + 20} }

	testing.expect(t, context_press(&ui, at(tr, r[1])), "a right-click on Settings")
	testing.expect(t, len(ui.msgs) == 1 && ui.msgs[0] == ResultRows_LMsg(101), "sends its context message")
	clear(&ui.msgs)

	pointer_move(&ui, at(tr, r[1]))
	testing.expect(t, len(ui.msgs) == 1 && ui.msgs[0] == ResultRows_LMsg(Rest{1, true}), "resting on Settings")
	clear(&ui.msgs)
	pointer_move(&ui, at(tr, r[1], 30))
	testing.expect_value(t, len(ui.msgs), 0) // moving within it
	pointer_move(&ui, at(tr, r[2]))
	testing.expect(t, len(ui.msgs) == 2 && ui.msgs[0] == ResultRows_LMsg(Rest{1, false}) && ui.msgs[1] == ResultRows_LMsg(Rest{2, true}), "off Settings, onto the emoji")
	clear(&ui.msgs)

	_, r = results(&ui, 0, gone = 1) // Settings goes: the emoji row moves up under the still pointer
	testing.expect_value(t, len(ui.msgs), 0)
	_, r = results(&ui, 0, gone = 2) // the row the pointer rested on goes
	testing.expect(t, len(ui.msgs) == 1 && ui.msgs[0] == ResultRows_LMsg(Rest{2, false}), "a row that goes hears the pointer leave it")
	clear(&ui.msgs)

	pointer_move(&ui, at(tr, r[0]))
	pointer_leave(&ui)
	testing.expect(t, len(ui.msgs) == 2 && ui.msgs[0] == ResultRows_LMsg(Rest{0, true}) && ui.msgs[1] == ResultRows_LMsg(Rest{0, false}), "leaving the surface ends a rest")
}

// A search field names the row its keys act on as its active item, in the accessibility tree.
@(test)
a_field_names_its_active_item :: proc(t: ^testing.T) {
	ui: Ui(ResultRows_LMsg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	field, r := results(&ui, 1)
	set_active_item(&ui.tree, field, r[1])
	dump := access_dump(&ui.tree)
	testing.expectf(t, strings.contains(dump, "Search_Box \"Search\"") && strings.contains(dump, "active=\"Settings\""), "the field names Settings:\n%s", dump)
}

// A glass layer surface is cleared to its panel tint, unless it gives its own
// clear: then it keeps its blur and draws only that (a launcher's scrim), and
// a rounded one draws no tinted shape.
@(test)
a_scrim_surface_keeps_its_blur_without_the_tint :: proc(t: ^testing.T) {
	th := theme_light()
	scrim := Color{0.03, 0.04, 0.05, 0.46}
	glassy := Surface_Desc(ResultRows_LMsg){kind = .Layer, transparent = true, backdrop = .Blur}
	tint := surface_clear(&th, glassy, true)
	testing.expect(t, tint != {} && tint != scrim, "a glass layer's own tint")
	dimmed := glassy
	dimmed.clear = scrim
	testing.expect_value(t, surface_clear(&th, dimmed, true), scrim)
	dimmed.radius = 16
	testing.expect_value(t, surface_shape(&th, dimmed, true), Color{})
	see_through := glassy
	see_through.clear = Color{}
	testing.expect_value(t, surface_clear(&th, see_through, true), Color{})
}

// A surface that appears under a still pointer (a launcher opening under the
// mouse) doesn't make the row under it heard as rested on: the pointer's first
// move over it does. The row is hovered all the same, so a click works at once.
@(test)
a_surface_appearing_under_the_pointer_is_no_rest :: proc(t: ^testing.T) {
	ui: Ui(ResultRows_LMsg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	_, r := results(&ui, 0)
	d := node_get(&ui.tree, r[2])
	p := [2]f32{d.abs.x + 80, d.abs.y + 20}
	pointer_move(&ui, p, moved = false) // the pointer enters the surface where it already was
	testing.expect_value(t, len(ui.msgs), 0)
	testing.expect_value(t, ui.pointer.hover, r[2])
	pointer_move(&ui, p + {4, 0})
	testing.expect(t, len(ui.msgs) == 1 && ui.msgs[0] == ResultRows_LMsg(Rest{2, true}), "the first move over it is a rest")
}

} // when ODIN_TEST