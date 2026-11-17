package baldr

@(require) import "core:fmt"
@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: they sit behind this `when` so an app does not pay
// for them. ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh
// check look inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// Picture tiles: a cover filling its square, a title and a muted subtitle, and Play over the cover on hover or for the keyboard's
// current tile; and reveal_within, which shows it.


@(private = "file")
Pt_Msg :: union { Pt_Play, Pt_Open }
@(private = "file") Pt_Play :: struct { i: int }
@(private = "file") Pt_Open :: struct { i: int }

@(private = "file")
albums :: proc(ui: ^Ui(Pt_Msg), sel: ^Selection, cover: ^Image) {
	set_viewport(&ui.tree, {800, 600})
	begin_view(ui)
	column(ui, flex = 1)
	first, last := icon_view(ui, 12, sel, on_activate = proc(e: Ev(int)) -> Pt_Msg { return Pt_Open{e.value} },
		label = "Albums", variant = .Pictures, key = 1)
	for i in first ..< last {
		icon_item(ui, i, .Disc_3, fmt.tprintf("A long album name number %d, deluxe edition", i), cover if i % 2 == 0 else nil,
			subtitle = "An artist with a long name", action = Pt_Msg(Pt_Play{i}), action_label = "Play")
	}
	end(ui)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {800, 600})
}

@(private = "file")
settle_tile :: proc(ui: ^Ui(Pt_Msg), sel: ^Selection, cover: ^Image) {
	albums(ui, sel, cover)
	for _ in 0 ..< 2 {
		ui.needs_rebuild = false
		ui_after_events(ui, 1)
		albums(ui, sel, cover)
	}
}

@(private = "file")
tile_of :: proc(ui: ^Ui(Pt_Msg), index: int) -> Node {
	for n, ref in ui.rows do if ref.index == index do return n
	return NODE_NONE
}

@(private = "file")
play_of :: proc(ui: ^Ui(Pt_Msg), tile: Node) -> (btn: Node) {
	find :: proc(t: ^Tree, n: Node) -> Node {
		d := node_get(t, n)
		if d == nil do return NODE_NONE
		if d.access.role == .Button do return n
		for c := d.first; c != NODE_NONE; c = node_get(t, c).next do if f := find(t, c); f != NODE_NONE do return f
		return NODE_NONE
	}
	return find(&ui.tree, tile)
}

@(private = "file")
drawn_within :: proc(ui: ^Ui(Pt_Msg), r: Rect, kind: typeid) -> (n: int) {
	for c in draw_list(&ui.tree) {
		if v, ok := c.(Draw_Icon); ok && kind == Draw_Icon && rect_contains(r, v.pos + {1, 1}) do n += 1
		if v, ok := c.(Draw_Image); ok && kind == Draw_Image && v.fit == .Cover && rect_contains(r, {v.rect.x + 1, v.rect.y + 1}) do n += 1
	}
	return
}

@(test)
a_picture_tile_is_a_cover_a_title_and_a_subtitle :: proc(t: ^testing.T) {
	ui: Ui(Pt_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	ui.tree.theme.motion.reduce = true
	sel := selection_make(multi = false)
	defer selection_destroy(&sel)
	px := make([]u8, 300 * 200 * 4, context.temp_allocator)
	cover, _ := image_from_rgba(300, 200, px) // not square: cropped, not letterboxed
	defer image_destroy(&cover)
	settle_tile(&ui, &sel, &cover)

	tile := tile_of(&ui, 0)
	td := node_get(&ui.tree, tile)
	testing.expect_value(t, [2]f32{td.abs.w, td.abs.h}, PICTURE_TILE)
	testing.expect_value(t, td.access.name, "A long album name number 0, deluxe edition")
	testing.expect_value(t, td.access.describe, "An artist with a long name") // heard after the name
	testing.expect_value(t, drawn_within(&ui, td.abs, Draw_Image), 1) // the cover, cropped to its square
	texts := 0
	for c := td.first; c != NODE_NONE; c = node_get(&ui.tree, c).next {
		if k, is := node_get(&ui.tree, c).kind.(Text_Kind); is {
			texts += 1
			testing.expect(t, k.nowrap && k.ellipsis == .End, "one line each, ended with …")
		}
	}
	testing.expect_value(t, texts, 2)
	testing.expect(t, drawn_within(&ui, node_get(&ui.tree, tile_of(&ui, 1)).abs, Draw_Icon) >= 1, "no cover: its icon on a quiet square")
}

@(test)
a_tiles_action_shows_on_hover_and_for_the_keyboard :: proc(t: ^testing.T) {
	ui: Ui(Pt_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	ui.tree.theme.motion.reduce = true
	sel := selection_make(multi = false)
	defer selection_destroy(&sel)
	settle_tile(&ui, &sel, nil)

	tile := tile_of(&ui, 2)
	play := play_of(&ui, tile)
	pd := node_get(&ui.tree, play)
	if pd == nil do testing.fail_now(t, "fixture: a Play button in the tile")
	testing.expect_value(t, pd.access.name, "Play")
	centre := [2]f32{pd.abs.x + pd.abs.w / 2, pd.abs.y + pd.abs.h / 2}
	shown :: proc(ui: ^Ui(Pt_Msg), r: Rect) -> bool {
		for c in draw_list(&ui.tree) do if ic, ok := c.(Draw_Icon); ok && ic.icon == .Play && rect_contains(r, ic.pos + {1, 1}) && ic.color.a > 0.5 do return true
		return false
	}
	testing.expect(t, !shown(&ui, pd.abs), "not over the cover until the tile is pointed at")
	testing.expect(t, interactive_target(&ui, hit_test(&ui.tree, centre)) != play, "and not there to be hit: a click there is the tile's")

	pointer_move(&ui, {node_get(&ui.tree, tile).abs.x + 20, node_get(&ui.tree, tile).abs.y + 20})
	frame(&ui.tree, {800, 600})
	testing.expect(t, shown(&ui, pd.abs), "shown on hover")
	pointer_move(&ui, centre) // onto the button itself: still shown
	frame(&ui.tree, {800, 600})
	testing.expect(t, shown(&ui, pd.abs), "still shown with the pointer on it")
	pointer_button(&ui, .Left, true, centre)
	pointer_button(&ui, .Left, false, centre)
	played := -1
	for m in ui.msgs do if p, ok := m.(Pt_Play); ok do played = p.i
	testing.expect_value(t, played, 2)

	pointer_leave(&ui)
	frame(&ui.tree, {800, 600})
	testing.expect(t, !shown(&ui, pd.abs), "gone with the pointer")

	// the keyboard: only the current tile's action is a Tab stop, and it shows
	view := node_parent(&ui.tree, node_parent(&ui.tree, node_parent(&ui.tree, tile)))
	for view != NODE_NONE && !(view in ui.tree.icon_views) do view = node_parent(&ui.tree, view)
	set_focus(&ui.tree, view, true)
	selection_set(&sel, 4)
	albums(&ui, &sel, nil)
	p4 := play_of(&ui, tile_of(&ui, 4))
	testing.expect(t, .Focusable in node_get(&ui.tree, p4).flags && .Focusable not_in node_get(&ui.tree, play_of(&ui, tile_of(&ui, 2))).flags, "one Tab stop: the current tile's")
	testing.expect(t, shown(&ui, node_get(&ui.tree, p4).abs), "the current tile's action is in sight")
}

} // when ODIN_TEST