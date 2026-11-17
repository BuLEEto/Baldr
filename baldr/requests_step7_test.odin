package baldr

@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: they sit behind this `when` so an app does not pay
// for them. ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh
// check look inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// A file view with a clicked row or tile leaves Space and Alt+arrows to the
// app's shortcuts (Quick Look, Back, Up).


@(private = "file")
VMsg :: enum { None, Look, Back, Up, Select }

@(private = "file")
file_view :: proc(ui: ^Ui(VMsg), sel: ^Selection, icons: bool) -> (view: Node) {
	set_viewport(&ui.tree, {800, 600})
	begin_view(ui)
	column(ui, flex = 1)
	shortcut(ui, "Space", VMsg.Look)
	shortcut(ui, "Alt+Left", VMsg.Back)
	shortcut(ui, "Alt+Up", VMsg.Up)
	if icons {
		first, last := icon_view(ui, 24, sel, on_select = proc(e: Ev(int)) -> VMsg { return .Select }, label = "Icons", flex = 1, key = 2)
		for i in first ..< last do icon_item(ui, i, .None, "b")
	} else {
		cols := []Column{{title = "Name"}}
		first, last := table(ui, cols, 24, sel, on_select = proc(e: Ev(int)) -> VMsg { return .Select }, label = "Files", flex = 1, key = 1)
		for i in first ..< last {
			table_row(ui, i)
			cell_text(ui, "a")
			end(ui)
		}
	}
	end(ui)
	end_view(ui)
	frame(&ui.tree, {800, 600})
	if icons {
		for n in ui.tree.icon_views do view = n
	} else {
		for n in ui.tree.tables do view = n
	}
	return
}

@(private = "file")
press :: proc(ui: ^Ui(VMsg), key: Key, mods: Mods) -> bool {
	return key_event(ui, key, true, mods) || shortcut_fire(ui, key, true, mods) // the run loop's order
}

@(private = "file")
click_item :: proc(t: ^testing.T, ui: ^Ui(VMsg), view: Node, index: int) {
	for n, ref in ui.rows {
		if ref.table != view || ref.index != index do continue
		d := node_get(&ui.tree, n)
		at := [2]f32{d.abs.x + min(d.abs.w / 2, 20), d.abs.y + d.abs.h / 2}
		pointer_move(ui, at)
		pointer_button(ui, .Left, true, at)
		pointer_button(ui, .Left, false, at)
		return
	}
	testing.fail_now(t, "no item node to click")
}

@(private = "file")
check_view :: proc(t: ^testing.T, icons: bool) {
	ui: Ui(VMsg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	sel := selection_make(multi = true)
	defer selection_destroy(&sel)
	view := file_view(&ui, &sel, icons)
	file_view(&ui, &sel, icons)
	click_item(t, &ui, view, 5)
	file_view(&ui, &sel, icons)
	testing.expect_value(t, sel.cursor, 5)
	clear(&ui.msgs)

	testing.expect(t, press(&ui, .Space, {}))
	testing.expectf(t, len(ui.msgs) == 1 && ui.msgs[0] == .Look, "Space is Quick Look (msgs %v, focus %v, view %v)", ui.msgs[:], ui.tree.focus, view)
	testing.expect(t, selection_count(&sel) == 1 && selection_contains(&sel, 5), "the selection stays")
	clear(&ui.msgs)
	press(&ui, .Up, {.Alt})
	testing.expectf(t, len(ui.msgs) == 1 && ui.msgs[0] == .Up, "Alt+Up is the enclosing folder (msgs %v)", ui.msgs[:])
	press(&ui, .Left, {.Alt})
	testing.expectf(t, len(ui.msgs) == 2 && ui.msgs[1] == .Back, "Alt+Left is Back (msgs %v)", ui.msgs[:])
	testing.expect_value(t, sel.cursor, 5) // neither moved the cursor
	press(&ui, .Down, {.Super})
	testing.expect_value(t, sel.cursor, 5)

	clear(&ui.msgs)
	testing.expect(t, press(&ui, .Down, {}), "a plain arrow is still the view's")
	testing.expect(t, sel.cursor > 5)
	cur := sel.cursor
	press(&ui, .Up, {.Shift})
	testing.expect(t, sel.cursor < cur && selection_count(&sel) >= 2, "Shift+arrow still extends")
	for m in ui.msgs do testing.expectf(t, m == .Select, "only selection changes (msgs %v)", ui.msgs[:])
	selection_set(&sel, -1) // no cursor: Enter has nothing to open
	clear(&ui.msgs)
	press(&ui, .Enter, {})
	testing.expectf(t, len(ui.msgs) == 0, "Enter with no cursor sends nothing (msgs %v)", ui.msgs[:])
}

@(test)
table_with_a_clicked_row_leaves_space_and_alt_arrows_to_the_app :: proc(t: ^testing.T) {
	check_view(t, icons = false)
}

@(test)
icon_view_with_a_clicked_tile_leaves_space_and_alt_arrows_to_the_app :: proc(t: ^testing.T) {
	check_view(t, icons = true)
}

} // when ODIN_TEST