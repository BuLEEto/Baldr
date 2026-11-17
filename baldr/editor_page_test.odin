package baldr

@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: about 9 GB without this `when`, 1 GB with it.
// ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh check look
// inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// An editor that fills a window draws no frame, and the chords that switch
// a window's tabs reach its shortcuts instead of being swallowed.


@(private = "file")
Pg_Msg :: union { int }

@(private = "file")
build :: proc(ui: ^Ui(Pg_Msg), doc: ^Document, frame: Maybe(bool) = nil, tabs := false) -> Node {
	begin_view(ui)
	column(ui, padding = .lg)
	n := text_area(ui, doc, label = "Notes", width = 420, height = 200)
	editor_options(ui, n, frame = frame)
	if tabs { // a window that switches its tabs with the usual chords
		shortcut(ui, "Ctrl+Page_Down", Pg_Msg(1))
		shortcut(ui, "Ctrl+Page_Up", Pg_Msg(2))
		shortcut(ui, "Ctrl+Tab", Pg_Msg(3))
	}
	end(ui)
	end_view(ui)
	frame_tree(&ui.tree, {600, 600})
	return n
}

@(private = "file")
frame_tree :: proc(t: ^Tree, size: [2]f32) { frame(t, size) }

// the border drawn around the editor, if any
@(private = "file")
border_of :: proc(t: ^Tree, n: Node) -> (r: Draw_Rect, drawn: bool) {
	d := node_get(t, n)
	for _, l in t.layers do for c in l.cmds {
		if v, ok := c.(Draw_Rect); ok && v.border_w > 0 && v.rect == d.abs do return v, true
	}
	return
}

@(test)
an_editor_that_is_the_page_draws_no_frame :: proc(t: ^testing.T) {
	ui: Ui(Pg_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	doc := document_make("a page of prose")
	defer document_destroy(&doc)
	n := build(&ui, &doc)
	area, s := editor_area(&ui.tree, n)
	set_focus(&ui.tree, area, true)
	build(&ui, &doc)
	framed, has := border_of(&ui.tree, area)
	testing.expect(t, has, "by default it is a field: a border")
	testing.expect_value(t, framed.border, ui.tree.theme.color.primary) // focused: the focus colour
	d := node_get(&ui.tree, area)
	testing.expect(t, d.style.radius > 0 && d.style.bg != {}, "…with rounded corners and a fill")

	build(&ui, &doc, frame = false)
	_, still := border_of(&ui.tree, area)
	testing.expect(t, !still, "the page draws no border, focused or not")
	testing.expect_value(t, d.style.radius, 0)
	testing.expect_value(t, d.style.bg, Color{})
	testing.expect(t, s.no_frame, "and it stays until changed")

	build(&ui, &doc, frame = true) // …and comes back
	back, again := border_of(&ui.tree, area)
	testing.expect(t, again && back.border == ui.tree.theme.color.primary, "asked for again, the frame is back")
	testing.expect(t, d.style.radius > 0 && d.style.bg != {}, "fill and corners too")
}

@(test)
an_editor_leaves_the_tab_switching_chords_to_the_window :: proc(t: ^testing.T) {
	ui: Ui(Pg_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	doc := document_make("one\ntwo\nthree\nfour\nfive\nsix\nseven\neight")
	defer document_destroy(&doc)
	n := build(&ui, &doc, tabs = true)
	area, s := editor_area(&ui.tree, n)
	set_focus(&ui.tree, area, true)
	editor_select(&ui, n, Pos{4, 0}, Pos{4, 0})

	// plain Page Up / Down stay the editor's, with or without Shift
	clear(&ui.msgs)
	took := key_event(&ui, .Page_Up, true, {})
	testing.expect(t, took && s.caret.block < 4, "plain Page Up moves the caret")
	testing.expect_value(t, len(ui.msgs), 0)
	editor_select(&ui, n, Pos{4, 0}, Pos{4, 0})
	took = key_event(&ui, .Page_Down, true, {.Shift})
	lo, hi, _ := editor_selection(&ui.tree, n)
	testing.expect(t, took && lo != hi, "Shift+Page Down extends the selection")

	// Ctrl+Page Up / Down are the window's
	editor_select(&ui, n, Pos{4, 0}, Pos{4, 0})
	was := s.caret
	clear(&ui.msgs)
	took = key_event(&ui, .Page_Down, true, {.Ctrl})
	fired := shortcut_fire(&ui, .Page_Down, true, {.Ctrl})
	testing.expect(t, !took && fired, "the editor declines Ctrl+Page Down and the window takes it")
	testing.expect_value(t, s.caret, was)
	testing.expect(t, len(ui.msgs) == 1 && ui.msgs[0] == Pg_Msg(1), "…as its own message")

	// Ctrl+Tab reaches a binding; without one it still moves focus out, as GTK does
	clear(&ui.msgs)
	took = key_event(&ui, .Tab, true, {.Ctrl})
	fired = shortcut_fire(&ui, .Tab, true, {.Ctrl})
	testing.expect(t, !took && fired, "a bound Ctrl+Tab is the window's")
	testing.expect_value(t, ui.tree.focus, area) // focus stayed in the editor
	testing.expect(t, len(ui.msgs) == 1 && ui.msgs[0] == Pg_Msg(3), "…with its message")

	build(&ui, &doc, tabs = false) // nothing bound
	set_focus(&ui.tree, area, true)
	clear(&ui.msgs)
	took = key_event(&ui, .Tab, true, {.Ctrl})
	testing.expect(t, took, "unbound, Ctrl+Tab moves focus as before")
	testing.expect_value(t, len(ui.msgs), 0)
}

} // when ODIN_TEST