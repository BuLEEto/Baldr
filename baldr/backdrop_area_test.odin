package baldr

@(require) import "core:testing"
@(require) import "baldr:platform"

// Test files are part of the package, so without this `when` every program
// that imports Baldr would type-check the whole suite too. ODIN_TEST is set
// by `odin test`; BALDR_TESTS lets ./build.sh check look inside.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// Glass behind parts of a layer surface, such as a shell's toasts.


@(private = "file")
BackdropArea_BMsg :: union { int }

@(private = "file")
Blur_Log :: struct {
	calls: int,
	rects: [dynamic][4]f32,
	radii: [dynamic]f32,
}

@(private = "file")
toasts :: proc(ui: ^Ui(BackdropArea_BMsg), count: int) -> (cards: [3]Node) {
	set_viewport(&ui.tree, {370, 400})
	begin_view(ui)
	column(ui, gap = 8, padding = 8, key = 1)
	for i in 0 ..< count {
		c := card(ui, glass = true, height = 72, key = u64(i + 1))
		backdrop_area(ui, c)
		text(ui, "A notification", key = 1)
		end(ui)
		cards[i] = c
	}
	end(ui)
	end_view(ui)
	frame(&ui.tree, {370, 400})
	return
}

// On a surface whose backdrop_region is Marked, the blur goes behind the
// marked cards only, rounded as they are, not the gaps between them: sent
// once, again when a toast comes, and where a gliding card is drawn. The
// setting is a live change, and such a surface is clear, with no tinted
// shape or highlight of its own.
@(test)
the_blur_follows_the_marked_cards :: proc(t: ^testing.T) {
	log: Blur_Log
	defer {
		delete(log.rects)
		delete(log.radii)
	}
	backend := platform.Backend{data = &log}
	backend.surface_set_blur_region = proc(b: ^platform.Backend, s: platform.Surface, rects: [][4]f32, radii: []f32) {
		lg := (^Blur_Log)(b.data)
		lg.calls += 1
		clear(&lg.rects)
		append(&lg.rects, ..rects)
		clear(&lg.radii)
		append(&lg.radii, ..radii)
	}
	ui: Ui(BackdropArea_BMsg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	tr := &ui.tree
	cards := toasts(&ui, 2)
	fc := Frame_Ctx{tree = tr, backend = &backend, surface = 1}
	defer delete(fc.blur_sent)

	backdrop_region_sync(&fc)
	testing.expect_value(t, log.calls, 0) // the whole surface: nothing to say
	fc.backdrop_region = .Marked
	backdrop_region_sync(&fc)
	c0, c1 := node_get(tr, cards[0]), node_get(tr, cards[1])
	testing.expect(t, log.calls == 1 && len(log.rects) == 2, "the two cards, not the gap between them")
	if len(log.rects) == 2 {
		testing.expect_value(t, log.rects[0], [4]f32{c0.abs.x, c0.abs.y, c0.abs.w, c0.abs.h})
		testing.expect_value(t, log.rects[1], [4]f32{c1.abs.x, c1.abs.y, c1.abs.w, c1.abs.h})
		testing.expect(t, log.radii[0] == c0.style.radius && c0.style.radius > 0, "rounded as the cards are")
	}
	backdrop_region_sync(&fc)
	testing.expect_value(t, log.calls, 1) // unchanged: not sent again

	cards = toasts(&ui, 3) // another toast
	backdrop_region_sync(&fc)
	testing.expect(t, log.calls == 2 && len(log.rects) == 3, "the new card too")

	d0 := node_get(tr, cards[0])
	d0.move_from = {0, 40} // gliding to its new place, half way
	anim_restart(tr, cards[0], .Move, 0.5, 0.5, 0)
	backdrop_region_sync(&fc)
	testing.expect(t, log.calls == 3 && len(log.rects) == 3 && log.rects[0][1] == d0.abs.y + 20, "the blur where the gliding card is drawn")

	a := Surface_Desc(BackdropArea_BMsg){kind = .Layer, transparent = true, backdrop = .Blur}
	m := a
	m.backdrop_region = .Marked
	testing.expect_value(t, surface_changes(a, m), Surface_Changes{.Backdrop})
	th := theme_dark()
	testing.expect(t, surface_clear(&th, a, true) != {} && surface_clear(&th, m, true) == {}, "clear between its cards")
	testing.expect(t, surface_highlight(&th, a, true) != {} && surface_highlight(&th, m, true) == {}, "no highlight of its own")
	rounded, rounded_marked := a, m
	rounded.radius, rounded_marked.radius = 16, 16
	testing.expect(t, surface_shape(&th, rounded, true) != {} && surface_shape(&th, rounded_marked, true) == {}, "no tinted shape of its own")

	backdrop_area(&ui, cards[0], false)
	testing.expect(t, .Backdrop_Area not_in d0.flags)
}

} // when ODIN_TEST