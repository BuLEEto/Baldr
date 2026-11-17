package baldr

@(require) import "core:testing"

// A row's leading slot takes an icon, a theme icon, a glyph or a decoded
// picture: a conversation list leads every row with a contact's avatar.
when ODIN_TEST || #config(BALDR_TESTS, false) {

@(private = "file")
Lri_Msg :: struct { i: int }

@(private = "file")
lri_avatar :: proc(t: ^testing.T) -> Image {
	px := []u8{
		255, 0, 0, 255,   0, 255, 0, 255,
		0, 0, 255, 255,   255, 255, 255, 255,
	}
	img, ok := image_from_rgba(2, 2, px)
	testing.expect(t, ok, "the test avatar decoded")
	return img
}

@(private = "file")
lri_build :: proc(ui: ^Ui(Lri_Msg), img: ^Image, glyph: string, variant: Row_Variant) -> Node {
	set_viewport(&ui.tree, {360, 200})
	begin_view(ui)
	column(ui, width = 320, padding = .sm)
	n := list_row(ui, "Ada Lovelace", Lri_Msg{1}, glyph = glyph, image = img,
		detail = "see you then", variant = variant, key = 1)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {360, 200})
	return n
}

@(private = "file")
lri_avatar_node :: proc(t: ^Tree, row: Node) -> Node {
	for c := node_get(t, row).first; c != NODE_NONE; c = node_get(t, c).next {
		if _, is_pic := t.pictures[c]; is_pic do return c
		for g := node_get(t, c).first; g != NODE_NONE; g = node_get(t, g).next { // inside a tile
			if _, is_pic := t.pictures[g]; is_pic do return g
		}
	}
	return NODE_NONE
}

// A row given a picture shows it, at the tile's size and round, and the row
// is still named by its label: an avatar is decoration, not content, and a
// screen reader should hear "Ada Lovelace", not "picture".
@(test)
a_row_given_a_picture_leads_with_it :: proc(t: ^testing.T) {
	av := lri_avatar(t)
	defer image_destroy(&av)
	ui: Ui(Lri_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)

	n := lri_build(&ui, &av, "", .Plain)
	a := lri_avatar_node(&ui.tree, n)
	testing.expect(t, a != NODE_NONE, "the row drew the picture")
	d := node_get(&ui.tree, a)
	testing.expect_value(t, d.rect.w, ICON_SIZE)
	testing.expect_value(t, d.rect.h, ICON_SIZE)
	testing.expect_value(t, d.style.radius, ICON_SIZE / 2) // round
	testing.expect_value(t, node_get(&ui.tree, a).access.role, Role.None)
	testing.expect_value(t, node_get(&ui.tree, n).access.name, "Ada Lovelace")

	// …and square when asked
	set_viewport(&ui.tree, {360, 200})
	begin_view(&ui)
	column(&ui, width = 320, padding = .sm)
	sq := list_row(&ui, "Group", Lri_Msg{2}, image = &av, image_round = false, key = 1)
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {360, 200})
	a2 := lri_avatar_node(&ui.tree, sq)
	testing.expect(t, a2 != NODE_NONE, "the square one is drawn too")
	testing.expect(t, node_get(&ui.tree, a2).style.radius < ICON_SIZE / 2, "and is not a circle")
}

// A tiled row puts the picture in the tile, where an app's icon goes, so a
// list of avatars lines up with a list of app icons.
@(test)
a_tiled_row_puts_the_picture_in_its_tile :: proc(t: ^testing.T) {
	av := lri_avatar(t)
	defer image_destroy(&av)
	ui: Ui(Lri_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)

	n := lri_build(&ui, &av, "", .Tile)
	a := lri_avatar_node(&ui.tree, n)
	testing.expect(t, a != NODE_NONE, "the tile holds the picture")
	testing.expect_value(t, node_get(&ui.tree, a).rect.w, LIST_ROW_TILE)
	testing.expect(t, node_parent(&ui.tree, a) != n, "and it is inside the tile, not beside it")
}

// With no picture the glyph shows (a contact's initial). Swapping one for
// the other must not
// hand the picture the glyph's node: they are different parts.
@(test)
a_row_without_a_picture_falls_back_to_its_glyph :: proc(t: ^testing.T) {
	av := lri_avatar(t)
	defer image_destroy(&av)
	ui: Ui(Lri_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)

	n := lri_build(&ui, nil, "A", .Plain)
	testing.expect_value(t, lri_avatar_node(&ui.tree, n), NODE_NONE)
	found := false
	for c := node_get(&ui.tree, n).first; c != NODE_NONE; c = node_get(&ui.tree, c).next {
		if tk, ok := node_get(&ui.tree, c).kind.(Text_Kind); ok && tk.str == "A" do found = true
	}
	testing.expect(t, found, "the initial is drawn instead")

	// the avatar arrives (the contact's picture loaded): the glyph goes and
	// the picture is a node of its own
	n2 := lri_build(&ui, &av, "A", .Plain)
	a := lri_avatar_node(&ui.tree, n2)
	testing.expect(t, a != NODE_NONE, "the picture took over")
	still := false
	for c := node_get(&ui.tree, n2).first; c != NODE_NONE; c = node_get(&ui.tree, c).next {
		if tk, ok := node_get(&ui.tree, c).kind.(Text_Kind); ok && tk.str == "A" do still = true
	}
	testing.expect(t, !still, "and the initial is gone, not sitting under it")
}

// `.Avatar` exists because a picture and an initial at their natural sizes
// are 36 px and 16 px, so the labels beside them would start at different
// places and the list would read ragged. The words start at the same x
// whatever the slot holds.
@(test)
avatar_rows_line_up_whatever_their_slot_holds :: proc(t: ^testing.T) {
	av := lri_avatar(t)
	defer image_destroy(&av)
	ui: Ui(Lri_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)

	set_viewport(&ui.tree, {360, 300})
	begin_view(&ui)
	column(&ui, width = 320, padding = .sm)
	pic := list_row(&ui, "Ada Lovelace", Lri_Msg{1}, image = &av, detail = "see you then", variant = .Avatar, key = 1)
	ini := list_row(&ui, "Bo Nielsen", Lri_Msg{2}, glyph = "B", detail = "no picture", variant = .Avatar, key = 2)
	ico := list_row(&ui, "Saved", Lri_Msg{3}, icon = .Bookmark, detail = "an icon", variant = .Avatar, key = 3)
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {360, 300})

	words_x :: proc(t: ^Tree, row: Node) -> f32 {
		for c := node_get(t, row).first; c != NODE_NONE; c = node_get(t, c).next {
			if node_get(t, c).key == u64(Control_Part.Label) do return node_get(t, c).abs.x
		}
		return -1
	}
	a, b, c := words_x(&ui.tree, pic), words_x(&ui.tree, ini), words_x(&ui.tree, ico)
	testing.expect(t, a > 0, "the picture row has a label column")
	testing.expectf(t, a == b, "a picture and an initial start their words at the same x (%.1f vs %.1f)", a, b)
	testing.expectf(t, a == c, "a picture and an icon too (%.1f vs %.1f)", a, c)

	// and the slot really is a circle, not the square tile
	slot := lri_avatar_node(&ui.tree, pic)
	testing.expect_value(t, node_get(&ui.tree, node_parent(&ui.tree, slot)).style.radius, LIST_ROW_TILE / 2)
}

}
