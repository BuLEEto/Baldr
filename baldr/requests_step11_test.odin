package baldr

@(require) import "core:testing"
@(require) import "baldr:gpu"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: they sit behind this `when` so an app does not pay
// for them. ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh
// check look inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// A click beside a segmented control's segments, and a fading dialog's
// released picture.


@(private = "file")
RequestsStep11_XMsg :: struct { kind: enum { None, Pick, Choose }, i: int }

@(private = "file")
settings :: proc(ui: ^Ui(RequestsStep11_XMsg)) -> (seg, rad: Node) {
	set_viewport(&ui.tree, {600, 300})
	begin_view(ui)
	column(ui, padding = .lg, gap = .md) // stretches its children, as a dialog's body does
	seg = segmented(ui, 1, {"List", "Icons"}, on_change = proc(e: Ev(int)) -> RequestsStep11_XMsg { return {kind = .Pick, i = e.value} }, label = "New folders open in")
	rad = radio(ui, 1, {"Ask", "Replace", "Skip"}, on_change = proc(e: Ev(int)) -> RequestsStep11_XMsg { return {kind = .Choose, i = e.value} }, label = "Conflicts", horizontal = true)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {600, 300})
	return
}

@(private = "file")
tap :: proc(ui: ^Ui(RequestsStep11_XMsg), at: [2]f32) {
	pointer_move(ui, at)
	pointer_button(ui, .Left, true, at)
	pointer_button(ui, .Left, false, at)
}

@(test)
a_click_beside_the_choices_picks_nothing :: proc(t: ^testing.T) {
	ui: Ui(RequestsStep11_XMsg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	seg, rad := settings(&ui)
	sd := node_get(&ui.tree, seg)
	items := ui.tree.choices[seg].items
	first, last := node_get(&ui.tree, items[0]), node_get(&ui.tree, items[len(items) - 1])
	testing.expect(t, sd.abs.x + sd.abs.w > last.abs.x + last.abs.w + 100, "stretched well past its segments")
	tap(&ui, {last.abs.x + last.abs.w + 60, sd.abs.y + sd.abs.h / 2}) // the empty track to the right of Icons
	tap(&ui, {sd.abs.x + 1, sd.abs.y + sd.abs.h / 2}) // the padding strip
	testing.expectf(t, len(ui.msgs) == 0, "nothing is picked (msgs %v)", ui.msgs[:])
	testing.expect_value(t, ui.tree.focus, seg) // the group takes focus
	key_event(&ui, .Space, true, {})
	testing.expectf(t, len(ui.msgs) == 0, "nor by Space on the group (msgs %v)", ui.msgs[:])
	tap(&ui, {first.abs.x + first.abs.w / 2, first.abs.y + first.abs.h / 2})
	testing.expect(t, len(ui.msgs) == 1 && ui.msgs[0].kind == .Pick && ui.msgs[0].i == 0, "a segment still picks")
	clear(&ui.msgs)

	ritems := ui.tree.choices[rad].items
	a, b := node_get(&ui.tree, ritems[0]), node_get(&ui.tree, ritems[1])
	tap(&ui, {(a.abs.x + a.abs.w + b.abs.x) / 2, a.abs.y + a.abs.h / 2}) // between two radios
	testing.expectf(t, len(ui.msgs) == 0, "nothing picked between radios (msgs %v)", ui.msgs[:])

	settings(&ui)
	track_right: f32
	for c in draw_list(&ui.tree) {
		if q, ok := c.(Draw_Rect); ok && q.color == ui.tree.theme.color.surface_variant && abs(q.rect.y - sd.abs.y) < 0.5 do track_right = max(track_right, q.rect.x + q.rect.w)
	}
	testing.expectf(t, track_right > 0 && track_right <= last.abs.x + last.abs.w + 3.5, "the track ends with the segments (%v, segments end at %v)", track_right, last.abs.x + last.abs.w)
}

@(private = "file")
look :: proc(ui: ^Ui(RequestsStep11_XMsg), img: ^Image, open: bool) {
	set_viewport(&ui.tree, {800, 600})
	begin_view(ui)
	column(ui)
	end(ui)
	if dialog(ui, open, RequestsStep11_XMsg{}, title = "Quick Look", width = 400, key = 9) {
		image(ui, img, width = 100, height = 100)
		end(ui)
	}
	end_view(ui)
	frame(&ui.tree, {800, 600})
}

// pictures counts the image draws holding `img`, those drawing a kept copy
// by id, and what rendering them all emits.
@(private = "file")
pictures :: proc(ui: ^Ui(RequestsStep11_XMsg), te: ^Text_Engine, img: ^Image) -> (by_pointer, by_id, rendered: int) {
	for c in draw_list(&ui.tree) {
		di, is := c.(Draw_Image)
		if !is do continue
		if di.img == img do by_pointer += 1
		if di.img == nil && di.id != 0 do by_id += 1
		out := make([dynamic]gpu.Cmd, context.temp_allocator)
		render_image(te, di, 1, nil, &out)
		rendered += len(out)
	}
	return
}

@(test)
a_fading_picture_never_reads_the_released_image :: proc(t: ^testing.T) {
	te: Text_Engine
	if !text_engine_init(&te) do testing.fail_now(t, "text_engine_init: embedded fonts failed to load")
	defer text_engine_destroy(&te)
	ui: Ui(RequestsStep11_XMsg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	img := new(Image)
	defer free(img)
	pixels := make([]u8, 64 * 64 * 4, context.temp_allocator)
	for &p in pixels do p = 200
	ok: bool
	img^, ok = image_from_rgba(64, 64, pixels)
	testing.expect(t, ok)

	now := 1000.0
	look(&ui, img, true)
	for now < 1400 {
		now += 16
		ui_tick(&ui, now)
		look(&ui, img, true)
	}
	p, i, r := pictures(&ui, &te, img)
	testing.expect(t, p == 1 && r == 1, "the open dialog draws the picture")
	testing.expect(t, img.id != 0)

	look(&ui, img, false) // Quick Look closed: the dialog starts to fade
	image_destroy(img) // and the app lets the picture go at once
	img.width, img.height, img.pixels = 1 << 20, 1 << 20, make([]u8, 4, context.temp_allocator) // what freed memory might claim: nothing may read it
	for _ in 0 ..< 3 {
		now += 16
		ui_tick(&ui, now)
		look(&ui, img, false)
	}
	p, i, r = pictures(&ui, &te, img)
	testing.expectf(t, p == 0, "the fading node no longer holds the Image (%d draws do)", p)
	testing.expectf(t, i == 1 && r == 1, "it fades with the copy the atlas kept (%d draws, %d rendered)", i, r)

	for now < 2400 {
		now += 16
		ui_tick(&ui, now)
		look(&ui, img, false)
	}
	p, i, _ = pictures(&ui, &te, img)
	testing.expect(t, p == 0 && i == 0, "gone once the fade is over")
	testing.expect_value(t, len(ui.tree.pictures), 0)
}

} // when ODIN_TEST