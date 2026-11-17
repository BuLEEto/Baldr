package baldr

@(require) import "core:strings"
@(require) import "core:testing"

when ODIN_TEST || #config(BALDR_TESTS, false) {

// Renaming an icon tile shows the whole name: the editor is a card over the
// tile, wrapping, two tiles wide, with a ground of its own, not a tile-wide
// one-line field showing a window of the name that scrolls with the caret.

@(private = "file")
LONG_NAME :: "Qwen-Image-LoRA-F16.gguf" // one line, once the card is two tiles wide
@(private = "file")
LONGER_NAME :: "Qwen-Image-LoRA-F16-v2-final-export-2026-10-21.gguf" // …and one that needs two lines even so

@(private = "file")
Irn_Msg :: struct {
	submitted: string,
	cancelled: bool,
}

@(private = "file")
Irn_Fx :: struct {
	ui:  Ui(Irn_Msg),
	sel: Selection,
}

// irn_view builds twelve tiles with the third one being renamed. Twice:
// the first build does not know the view's width, so the flow has not put
// the tiles in their rows yet.
@(private = "file")
irn_view :: proc(fx: ^Irn_Fx, editing := 2, name := LONG_NAME) -> (view, tile, neighbour: Node) {
	for _ in 0 ..< 2 do irn_build(fx, editing, name)
	t := &fx.ui.tree
	col := node_first(t, fx.ui.root)
	view = node_first(t, col)
	tile = irn_tile(t, view, u64(editing))
	neighbour = irn_tile(t, view, u64(editing + 1))
	return
}

// irn_tile finds a built tile by its index.
@(private = "file")
irn_tile :: proc(t: ^Tree, n: Node, tag: u64) -> Node {
	for c := node_first(t, n); c != NODE_NONE; c = node_next(t, c) {
		d := node_get(t, c)
		if d == nil do continue
		if d.access.role == .List_Item && d.tag == tag do return c
		if found := irn_tile(t, c, tag); found != NODE_NONE do return found
	}
	return NODE_NONE
}

@(private = "file")
irn_build :: proc(fx: ^Irn_Fx, editing: int, name: string) {
	ui := &fx.ui
	begin_view(ui)
	column(ui, flex = 1)
	first, last := icon_view(ui, 12, &fx.sel, label = "Files", key = 5)
	for i in first ..< last {
		if i == editing {
			icon_item(ui, i, .File, name,
				on_submit = proc(e: Ev(string)) -> Irn_Msg { return {submitted = e.value} },
				on_cancel = Irn_Msg{cancelled = true})
		} else {
			icon_item(ui, i, .File, "short.txt")
		}
	}
	end(ui)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {600, 400})
}

// irn_editor is the Text_Input the overlay holds, and its card.
@(private = "file")
irn_editor :: proc(t: ^Tree) -> (card, editor: Node) {
	for c := node_first(t, t.overlay); c != NODE_NONE; c = node_next(t, c) {
		for e := node_first(t, c); e != NODE_NONE; e = node_next(t, e) {
			if d := node_get(t, e); d != nil && d.access.role == .Text_Input do return c, e
		}
	}
	return NODE_NONE, NODE_NONE
}

@(test)
an_icon_tiles_rename_shows_the_whole_name :: proc(t: ^testing.T) {
	fx: Irn_Fx
	ui_init(&fx.ui)
	defer ui_destroy(&fx.ui)
	fx.sel = selection_make(multi = true)
	defer selection_destroy(&fx.sel)
	tr := &fx.ui.tree
	view, tile, neighbour := irn_view(&fx, name = LONGER_NAME)
	testing.expect(t, view != NODE_NONE && tile != NODE_NONE && neighbour != NODE_NONE, "a view, a tile and the one after it")
	if tile == NODE_NONE || neighbour == NODE_NONE do return

	card, ed := irn_editor(tr)
	testing.expect(t, ed != NODE_NONE, "the editor is in the overlay, not in the tile")
	if ed == NODE_NONE do return
	ed_d, card_d, tile_d := node_get(tr, ed), node_get(tr, card), node_get(tr, tile)
	testing.expect_value(t, card_d.parent, tr.overlay)
	testing.expect_value(t, ed_d.access.name, "Rename")

	// the whole name is in it, and the stem is selected
	s := &tr.areas[ed]
	testing.expect(t, s != nil && s.doc != nil, "it holds a document of its own")
	if s == nil || s.doc == nil do return
	testing.expect_value(t, document_text(s.doc, context.temp_allocator), LONGER_NAME)
	testing.expect_value(t, s.anchor, Pos{0, 0})
	testing.expect_value(t, s.caret, Pos{0, stem_end(LONGER_NAME)}) // ".gguf" left out
	testing.expect_value(t, tr.focus, ed)

	// wider than the tile, centred on it, and over its neighbour
	testing.expect(t, card_d.abs.w > tile_d.abs.w + 1, "wider than the tile it belongs to")
	testing.expect(t, card_d.abs.w <= tile_d.abs.w * 2 + 1, "…and no wider than two of them")
	mid_card := card_d.abs.x + card_d.abs.w / 2
	mid_tile := tile_d.abs.x + tile_d.abs.w / 2
	testing.expectf(t, abs(mid_card - mid_tile) < 1, "centred on its tile (%.1f, %.1f)", mid_card, mid_tile)
	testing.expect(t, rect_intersects(card_d.abs, node_get(tr, neighbour).abs), "drawn over its neighbour")

	// it wraps: the name does not fit on one line at that width, and the
	// editor is as tall as the lines it took
	content := tr.scrolls[ed].content.y
	lines := int(content / max(s.line_h, 1) + 0.5)
	testing.expectf(t, lines >= 2, "over as many lines as it needs (%d lines of %.1f px)", lines, s.line_h)
	testing.expect(t, ed_d.abs.h >= content - 0.5, "and shows all of them at once")
	testing.expect(t, card_d.abs.h > tile_d.abs.h / 3, "and the card grew with it")
}

// A name that fits two tiles wide needs no wrapping, and nothing of it is
// scrolled out of sight sideways.
@(test)
the_name_from_the_report_is_shown_whole :: proc(t: ^testing.T) {
	fx: Irn_Fx
	ui_init(&fx.ui)
	defer ui_destroy(&fx.ui)
	fx.sel = selection_make(multi = true)
	defer selection_destroy(&fx.sel)
	tr := &fx.ui.tree
	irn_view(&fx)
	_, ed := irn_editor(tr)
	if ed == NODE_NONE {
		testing.fail(t)
		return
	}
	s := &tr.areas[ed]
	st := tr.scrolls[ed]
	lines := int(st.content.y / max(s.line_h, 1) + 0.5)
	testing.expect_value(t, lines, 1)
	testing.expect(t, st.content.x <= st.viewport.x + 0.5, "and no window of it that scrolls sideways")
	testing.expect(t, node_get(tr, ed).abs.h >= st.content.y - 0.5, "the line is shown whole")
}

// A card centred on a tile in the first or last column would hang past the
// view's edge over whatever is beside it, such as a sidebar. It is
// kept inside the view's width, and the view is not the window: this
// fixture puts a sidebar to its left.
@(test)
a_rename_card_stays_inside_its_view :: proc(t: ^testing.T) {
	for editing in ([]int{0, 4}) { // the first column, then the last of the row
		fx: Irn_Fx
		ui_init(&fx.ui)
		defer ui_destroy(&fx.ui)
		fx.sel = selection_make(multi = true)
		defer selection_destroy(&fx.sel)
		tr := &fx.ui.tree
		view, tile: Node
		for _ in 0 ..< 2 {
			ui := &fx.ui
			begin_view(ui)
			row(ui, flex = 1)
			box(ui, width = 220, height = 400) // a sidebar: the view does not start at the window's edge
			first, last := icon_view(ui, 12, &fx.sel, label = "Files", key = 5)
			for i in first ..< last {
				if i == editing {
					icon_item(ui, i, .File, LONGER_NAME,
						on_submit = proc(e: Ev(string)) -> Irn_Msg { return {submitted = e.value} })
				} else {
					icon_item(ui, i, .File, "short.txt")
				}
			}
			end(ui)
			end(ui)
			end_view(ui)
			frame(tr, {600, 400})
		}
		r := node_first(tr, fx.ui.root)
		view = node_next(tr, node_first(tr, r))
		tile = irn_tile(tr, view, u64(editing))
		card, ed := irn_editor(tr)
		testing.expect(t, view != NODE_NONE && tile != NODE_NONE && ed != NODE_NONE, "a view, its tile and the editor")
		if view == NODE_NONE || tile == NODE_NONE || ed == NODE_NONE do return
		vd, cardd, td := node_get(tr, view), node_get(tr, card), node_get(tr, tile)
		testing.expect(t, vd.abs.x > 200, "fixture: the view starts past the sidebar")
		testing.expectf(t, cardd.abs.x >= vd.abs.x - 0.5, "tile %d: its left edge (%.1f) is inside the view (%.1f)", editing, cardd.abs.x, vd.abs.x)
		testing.expectf(t, cardd.abs.x + cardd.abs.w <= vd.abs.x + vd.abs.w + 0.5,
			"tile %d: its right edge (%.1f) is inside the view (%.1f)", editing, cardd.abs.x + cardd.abs.w, vd.abs.x + vd.abs.w)
		testing.expect(t, rect_intersects(cardd.abs, td.abs), "…and still over the tile it belongs to")
	}
}

@(test)
an_icon_rename_commits_on_enter_and_reverts_on_escape :: proc(t: ^testing.T) {
	{ // Enter commits the whole name, not the window of it that was shown
		fx: Irn_Fx
		ui_init(&fx.ui)
		defer ui_destroy(&fx.ui)
		fx.sel = selection_make(multi = true)
		defer selection_destroy(&fx.sel)
		irn_view(&fx)
		_, ed := irn_editor(&fx.ui.tree)
		if ed == NODE_NONE {
			testing.fail(t)
			return
		}
		clear(&fx.ui.msgs)
		testing.expect(t, key_event(&fx.ui, .Enter, true, {}), "Enter is the editor's")
		testing.expect_value(t, len(fx.ui.msgs), 1)
		if len(fx.ui.msgs) == 1 do testing.expect_value(t, fx.ui.msgs[0].submitted, LONG_NAME)
	}
	{ // Escape reverts
		fx: Irn_Fx
		ui_init(&fx.ui)
		defer ui_destroy(&fx.ui)
		fx.sel = selection_make(multi = true)
		defer selection_destroy(&fx.sel)
		irn_view(&fx)
		clear(&fx.ui.msgs)
		testing.expect(t, key_event(&fx.ui, .Escape, true, {}), "Escape is the editor's")
		testing.expect_value(t, len(fx.ui.msgs), 1)
		if len(fx.ui.msgs) == 1 do testing.expect(t, fx.ui.msgs[0].cancelled, "on_cancel, and nothing submitted")
	}
}

@(test)
a_renamed_tile_commits_what_was_typed_without_its_newlines :: proc(t: ^testing.T) {
	fx: Irn_Fx
	ui_init(&fx.ui)
	defer ui_destroy(&fx.ui)
	fx.sel = selection_make(multi = true)
	defer selection_destroy(&fx.sel)
	irn_view(&fx)
	_, ed := irn_editor(&fx.ui.tree)
	if ed == NODE_NONE {
		testing.fail(t)
		return
	}
	// typing replaces the selected stem, as a rename does
	text_area_text(&fx.ui, "Qwen 2")
	s := &fx.ui.tree.areas[ed]
	testing.expect_value(t, document_text(s.doc, context.temp_allocator), "Qwen 2.gguf")
	// A paste keeps its newlines in a multi-line editor, so the name must
	// drop them: "Qwen 2\nand more.gguf" is not a name the app can use.
	fx.ui.tree.clipboard = {
		get = proc(user: rawptr, allocator := context.allocator) -> (string, bool) {
			return strings.clone(" and\nmore", allocator), true
		},
	}
	s.caret = document_end(s.doc)
	s.anchor = s.caret
	testing.expect(t, area_action(&fx.ui, ed, s, .Paste), "the paste went in")
	testing.expect(t, strings.contains_rune(document_text(s.doc, context.temp_allocator), '\n'), "with its newline")
	clear(&fx.ui.msgs)
	key_event(&fx.ui, .Enter, true, {})
	testing.expect_value(t, len(fx.ui.msgs), 1)
	if len(fx.ui.msgs) == 1 {
		testing.expect(t, !strings.contains_rune(fx.ui.msgs[0].submitted, '\n'), fx.ui.msgs[0].submitted)
		testing.expect_value(t, fx.ui.msgs[0].submitted, "Qwen 2.gguf and more")
	}
}

@(test)
an_icon_rename_commits_when_the_keyboard_leaves :: proc(t: ^testing.T) {
	fx: Irn_Fx
	ui_init(&fx.ui)
	defer ui_destroy(&fx.ui)
	fx.sel = selection_make(multi = true)
	defer selection_destroy(&fx.sel)
	view, _, _ := irn_view(&fx)
	clear(&fx.ui.msgs)
	set_focus(&fx.ui.tree, view, false) // a press on the view behind it
	inline_tick(&fx.ui, fx.ui.tree.now_ms + 1)
	testing.expect_value(t, len(fx.ui.msgs), 1)
	if len(fx.ui.msgs) == 1 do testing.expect_value(t, fx.ui.msgs[0].submitted, LONG_NAME) // leaving a field commits
}

}
