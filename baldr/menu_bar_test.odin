package baldr

@(require) import "core:testing"
@(require) import "baldr:gpu"

// Behind this `when` so a program importing Baldr does not type-check the
// test suite too, which costs gigabytes. ODIN_TEST is set by `odin test`;
// BALDR_TESTS lets ./build.sh check look inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

@(private = "file")
bar_view :: proc(ui: ^Ui(Ov_Msg)) -> (bar: Node) {
	set_viewport(&ui.tree, {600, 400})
	begin_view(ui)
	column(ui)
	bar = menu_bar(ui)
	if menu_bar_menu(ui, "File") {
		menu_item(ui, "New", Ov_Msg{kind = .Pick, i = 1}, shortcut = "Ctrl+N")
		menu_item(ui, "Quit", Ov_Msg{kind = .Delete})
		end(ui)
	}
	if menu_bar_menu(ui, "Edit") {
		menu_item(ui, "Undo", Ov_Msg{kind = .Pick, i = 2}, shortcut = "Ctrl+Z")
		end(ui)
	}
	if menu_bar_menu(ui, "Help") {
		menu_item(ui, "About", Ov_Msg{kind = .Pick, i = 3})
		end(ui)
	}
	end(ui)
	text(ui, "page")
	end(ui)
	end_view(ui)
	frame(&ui.tree, {600, 400})
	return
}

@(private = "file")
rebuild :: proc(ui: ^Ui(Ov_Msg)) -> Node {
	ui.needs_rebuild = false
	return bar_view(ui)
}


// A menu bar does not hold the keys once its menu has closed, or the app's
// own Enter would open the menu again. A click on a title never takes the
// keys (Tab and F10 still reach it), and a menu closing by a chosen item or
// a press away gives them back to whatever had them before it opened. Escape
// is the exception and gives them to the title, so the bar stays navigable,
// as on other desktops.
@(test)
a_menu_bar_gives_the_keys_back_when_its_menu_closes :: proc(t: ^testing.T) {
	ui: Ui(Ov_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	bar := bar_view(&ui)
	tr := &ui.tree
	mb := ui.menu_bars[bar]
	file := mb.titles[0]

	// Nothing has the keyboard to begin with: the page's text is not
	// focusable.
	testing.expect_value(t, tr.focus, NODE_NONE)

	fd := node_get(tr, file)
	p := [2]f32{fd.abs.x + 10, fd.abs.y + 10}
	pointer_move(&ui, p)
	pointer_button(&ui, .Left, true, p)
	testing.expect_value(t, tr.focus, NODE_NONE) // the click did not take them
	pointer_button(&ui, .Left, false, p)
	rebuild(&ui)
	testing.expect_value(t, ui.menu_bars[bar].open, 0)
	testing.expect_value(t, node_get(tr, tr.focus).access.name, "New") // the menu has them

	// Choosing an item closes it and gives them back where they were: here,
	// nowhere — so the app's own Enter shortcut is free again.
	item := node_first(tr, node_first(tr, tr.overlay))
	id := node_get(tr, item)
	q := [2]f32{id.abs.x + 10, id.abs.y + 5}
	pointer_move(&ui, q)
	pointer_button(&ui, .Left, true, q)
	pointer_button(&ui, .Left, false, q)
	rebuild(&ui)
	ui_tick(&ui, 5000)
	testing.expect_value(t, ui.menu_bars[bar].open, -1)
	testing.expect_value(t, tr.focus, NODE_NONE)
}

@(test)
menu_bar_opens_switches_and_is_keyboard_operable :: proc(t: ^testing.T) {
	ui: Ui(Ov_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	bar := bar_view(&ui)
	bd := node_get(&ui.tree, bar)
	testing.expect_value(t, bd.access.role, Role.Menu_Bar)
	testing.expect_value(t, node_child_count(&ui.tree, bar), 3)
	mb := ui.menu_bars[bar]
	testing.expect_value(t, mb.open, -1)
	testing.expect(t, lint(&ui.tree) == 0)
	file := mb.titles[0]
	fd := node_get(&ui.tree, file)
	testing.expect_value(t, fd.access.role, Role.Menu_Item)
	testing.expect(t, .Collapsed in fd.access.states)
	// click File: it opens, the dropdown is a Menu with focus on its first item
	p := [2]f32{fd.abs.x + 10, fd.abs.y + 10}
	pointer_move(&ui, p)
	pointer_button(&ui, .Left, true, p)
	pointer_button(&ui, .Left, false, p)
	testing.expect(t, ui.open[file] && ui.needs_rebuild)
	rebuild(&ui)
	mb = ui.menu_bars[bar]
	testing.expect_value(t, mb.open, 0)
	testing.expect(t, .Expanded in node_get(&ui.tree, file).access.states)
	pop := node_first(&ui.tree, ui.tree.overlay)
	testing.expect(t, pop != NODE_NONE)
	testing.expect_value(t, node_get(&ui.tree, pop).access.role, Role.Menu)
	testing.expect_value(t, node_child_count(&ui.tree, pop), 2)
	testing.expect_value(t, node_get(&ui.tree, ui.tree.focus).access.name, "New")
	// hovering Edit while File is open switches
	edit := mb.titles[1]
	ed := node_get(&ui.tree, edit)
	pointer_move(&ui, {ed.abs.x + 10, ed.abs.y + 10})
	testing.expect(t, ui.needs_rebuild)
	rebuild(&ui)
	mb = ui.menu_bars[bar]
	testing.expect_value(t, mb.open, 1)
	testing.expect(t, !ui.open[file] && ui.open[edit])
	pop = node_first(&ui.tree, ui.tree.overlay)
	testing.expect_value(t, node_get(&ui.tree, node_first(&ui.tree, pop)).access.name, "Undo")
	// Right from inside the menu jumps to Help; Escape closes and focus returns to the title
	set_focus(&ui.tree, node_first(&ui.tree, pop), true)
	testing.expect(t, key_event(&ui, .Right, true, {}))
	rebuild(&ui)
	mb = ui.menu_bars[bar]
	testing.expect_value(t, mb.open, 2)
	testing.expect(t, key_event(&ui, .Escape, true, {}))
	rebuild(&ui)
	mb = ui.menu_bars[bar]
	testing.expect_value(t, mb.open, -1)
	testing.expect_value(t, ui.tree.focus, mb.titles[2])
	fading := node_child_count(&ui.tree, ui.tree.overlay)
	testing.expect(t, fading >= 1 && fading <= 3, "the menus we opened are fading out") // each title has its own dropdown node
	ui_tick(&ui, 5000)
	testing.expect_value(t, node_child_count(&ui.tree, ui.tree.overlay), 0)
	// keyboard: F10 focuses File; Right moves to Edit; Down opens it; Enter on an item fires and closes
	set_focus(&ui.tree, NODE_NONE, false)
	testing.expect(t, key_event(&ui, .F10, true, {}))
	testing.expect_value(t, ui.tree.focus, mb.titles[0])
	testing.expect(t, key_event(&ui, .Right, true, {}))
	testing.expect_value(t, ui.tree.focus, mb.titles[1])
	testing.expect(t, key_event(&ui, .Down, true, {}))
	rebuild(&ui)
	testing.expect_value(t, ui.menu_bars[bar].open, 1)
	testing.expect_value(t, node_get(&ui.tree, ui.tree.focus).access.name, "Undo")
	before := len(ui.msgs)
	testing.expect(t, key_event(&ui, .Enter, true, {}))
	testing.expect_value(t, ui.msgs[before].kind, Ov_Kind.Pick)
	testing.expect_value(t, ui.msgs[before].i, 2)
	rebuild(&ui)
	testing.expect_value(t, ui.menu_bars[bar].open, -1)
	// a press elsewhere closes an open menu
	key_event(&ui, .Down, true, {})
	rebuild(&ui)
	testing.expect_value(t, ui.menu_bars[bar].open, 1)
	pointer_button(&ui, .Left, true, {300, 300})
	rebuild(&ui)
	testing.expect_value(t, ui.menu_bars[bar].open, -1)
}

@(test)
image_decodes_draws_rounded_and_uploads_once :: proc(t: ^testing.T) {
	ui: Ui(Ov_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	te: Text_Engine
	text_engine_init(&te)
	defer text_engine_destroy(&te)
	tree_use_text_engine(&ui.tree, &te)
	// a 4×2 RGBA test image
	px := []u8{255,0,0,255, 0,255,0,255, 0,0,255,255, 255,255,255,255, 0,0,0,255, 128,128,128,255, 255,0,255,255, 0,255,255,128}
	img, ok := image_from_rgba(4, 2, px)
	testing.expect(t, ok)
	defer image_destroy(&img)
	set_viewport(&ui.tree, {300, 200})
	begin_view(&ui)
	row(&ui, gap = .sm, align = .Center)
	pic := image(&ui, &img, width = 80, radius = 8, label = "Test picture")
	deco := image(&ui, &img, height = 20)
	b := button(&ui, "Profile", Ov_Msg{}, image = &img, variant = .Outline)
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {300, 200})
	pd := node_get(&ui.tree, pic)
	testing.expect_value(t, pd.abs.w, 80)
	testing.expect_value(t, pd.abs.h, 40) // aspect kept
	testing.expect_value(t, pd.access.role, Role.Image)
	testing.expect_value(t, pd.access.name, "Test picture")
	dd := node_get(&ui.tree, deco)
	testing.expect_value(t, dd.abs.w, 40)
	testing.expect_value(t, dd.access.role, Role.None)
	testing.expect_value(t, node_child_count(&ui.tree, b), 2) // picture + label
	testing.expect(t, lint(&ui.tree) == 0)
	images := 0
	for c in draw_list(&ui.tree) do if di, has := c.(Draw_Image); has {
		images += 1
		if di.rect.w == 80 do testing.expect_value(t, di.radius, 8)
	}
	testing.expect_value(t, images, 3)
	cmds := make([dynamic]gpu.Cmd, context.temp_allocator)
	render_prepare(&ui.tree, 1, nil, &cmds)
	gpu_images := 0
	full_u, cropped_u: f32
	for c in cmds do if gi, has := c.(gpu.Image); has {
		gpu_images += 1
		testing.expect(t, gi.uv[2] > gi.uv[0] && gi.uv[3] > gi.uv[1], "a real atlas region")
		if gi.rect.z == 80 do full_u = gi.uv[2] - gi.uv[0]          // 2:1 box, 2:1 picture: whole region
		if gi.rect.z == BUTTON_IMAGE_SIZE do cropped_u = gi.uv[2] - gi.uv[0] // square box: sides cropped
	}
	testing.expect_value(t, gpu_images, 3)
	testing.expect(t, cropped_u > 0 && abs(cropped_u - full_u / 2) < 1e-4, "cover fit crops a 2:1 picture to half its width in a square")
	testing.expect_value(t, len(te.images), 1) // one upload for all three draws
	clear(&cmds)
	render_prepare(&ui.tree, 2, nil, &cmds)
	testing.expect_value(t, len(te.images), 1) // and none for a new scale
	img.version += 1
	clear(&cmds)
	render_prepare(&ui.tree, 1, nil, &cmds)
	testing.expect_value(t, len(te.images), 2) // a new version re-uploads
	// PNG decode through the core decoder
	png_bytes := #load("../assets/sample/avatar.png")
	decoded, dok := image_load(png_bytes)
	testing.expect(t, dok)
	defer image_destroy(&decoded)
	testing.expect_value(t, decoded.width, 96)
	testing.expect_value(t, decoded.height, 96)
	testing.expect_value(t, decoded.pixels[3], 255)
	// a picture larger than a page is downscaled to fit
	big := make([]u8, 2000 * 300 * 4, context.temp_allocator)
	for i in 0 ..< len(big) do big[i] = 200
	huge, hok := image_from_rgba(2000, 300, big, context.temp_allocator)
	testing.expect(t, hok)
	slot, sok := image_slot(&te, &huge)
	testing.expect(t, sok)
	testing.expect(t, slot.px_size.x <= ATLAS_PAGE_SIZE && slot.px_size.x >= 900, "downscaled by an integer factor to fit")
}

@(test)
menu_bar_swaps_menus_at_once :: proc(t: ^testing.T) {
	// Once a menu is open, moving along the bar swaps menus at once, as every
	// desktop does: only opening the first and closing the last animate.
	ui: Ui(Ov_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	bar := bar_view(&ui)
	mb := ui.menu_bars[bar]

	// opening the first still fades in
	click(&ui, mb.titles[0])
	rebuild(&ui)
	first := node_first(&ui.tree, ui.tree.overlay)
	testing.expect(t, first != NODE_NONE, "File's dropdown is open")
	testing.expect_value(t, node_get(&ui.tree, first).style.enter.kind, Transition_Kind.Fade_Scale)

	// moving along the bar swaps: the one leaving goes at once…
	menu_bar_switch(&ui, bar, 1, false)
	testing.expect_value(t, node_get(&ui.tree, first).style.exit.kind, Transition_Kind.None)
	rebuild(&ui)
	testing.expect(t, !node_valid(&ui.tree, first) || .Exiting not_in node_get(&ui.tree, first).flags,
		"it is gone, not fading")

	// …and the one arriving comes without an enter of its own
	arrived := NODE_NONE
	for c := node_first(&ui.tree, ui.tree.overlay); c != NODE_NONE; c = node_next(&ui.tree, c) do arrived = c
	testing.expect(t, arrived != NODE_NONE && arrived != first, "Edit's dropdown took its place")
	testing.expect_value(t, node_get(&ui.tree, arrived).style.enter.kind, Transition_Kind.None)

	// closing the last one keeps its fade out
	testing.expect_value(t, node_get(&ui.tree, arrived).style.exit.kind, Transition_Kind.Fade)
}

} // when ODIN_TEST