package baldr

@(require) import "core:testing"
@(require) import "baldr:platform"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too; behind this `when` an app does not pay for them.
// ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh check look
// inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

Sf_Msg :: enum { Close_Panel, Close_Launcher }

ALL_CAPS :: platform.Caps{.Transparent, .Backdrop_Blur, .Layer_Shell, .Session_Lock}

@(private = "file")
panel_desc :: proc() -> Surface_Desc(Sf_Msg) {
	return {
		tag = 1, kind = .Layer, size = {0, 36},
		layer = {level = .Top, anchor = {.Top, .Left, .Right}, exclusive_zone = 36, keyboard = .On_Demand},
		transparent = true, backdrop = .Blur, on_close = Sf_Msg.Close_Panel,
	}
}

// The runtime opens what the app newly declares and closes what it stopped
// declaring, by tag, in declaration order; surfaces still wanted are left alone.
@(test)
surface_diff_opens_new_and_closes_gone :: proc(t: ^testing.T) {
	open := []u64{1, 2, 3}
	want := []u64{3, 4, 1, 5}
	to_open, to_close := surface_diff(open, want)
	testing.expect_value(t, len(to_open), 2)
	testing.expect_value(t, want[to_open[0]], u64(4))
	testing.expect_value(t, want[to_open[1]], u64(5))
	testing.expect_value(t, len(to_close), 1)
	testing.expect_value(t, open[to_close[0]], u64(2))
	// nothing wanted: everything closes; nothing open: everything opens
	_, all_close := surface_diff(open, {})
	testing.expect_value(t, len(all_close), 3)
	all_open, _ := surface_diff({}, want)
	testing.expect_value(t, len(all_open), 4)
}

// A layer surface stays a layer surface only where layer shell exists;
// elsewhere it is an undecorated window with a real size. Transparency and
// blur are dropped, never faked, when the backend cannot do them.
@(test)
surface_resolve_degrades_to_what_the_backend_can_do :: proc(t: ^testing.T) {
	d := panel_desc()
	full := surface_resolve(d, ALL_CAPS, "test.app")
	testing.expect_value(t, full.kind, platform.Surface_Kind.Layer)
	testing.expect_value(t, full.layer.exclusive_zone, i32(36))
	testing.expect_value(t, full.size, [2]f32{0, 36})
	testing.expect(t, full.transparent && full.backdrop == .Blur, "all asked for, all granted")
	testing.expect_value(t, full.app_id, "test.app")

	bare := surface_resolve(d, {}, "test.app")
	testing.expect_value(t, bare.kind, platform.Surface_Kind.Window)
	testing.expect(t, bare.undecorated, "a fallback panel window draws no frame")
	testing.expect(t, bare.size.x > 0 && bare.size.y > 0, "a stretched dimension gets a real size for a window")
	testing.expect(t, !bare.transparent && bare.backdrop == .None, "no transparency without the capability")

	no_blur := surface_resolve(d, {.Transparent, .Layer_Shell}, "test.app")
	testing.expect(t, no_blur.transparent && no_blur.backdrop == .None, "transparent but no blur request without the compositor effect")
}

// Glass shows through only when the theme allows it, the app asked for a
// blur backdrop, and the compositor can blur.
@(test)
surface_glass_needs_theme_request_and_compositor :: proc(t: ^testing.T) {
	d := panel_desc()
	testing.expect(t, surface_glass(d, ALL_CAPS, .Frosted))
	testing.expect(t, surface_glass(d, ALL_CAPS, .Clear))
	testing.expect(t, !surface_glass(d, ALL_CAPS, .Solid), "Solid glass (and OS reduce-transparency, which makes it so) wins")
	testing.expect(t, !surface_glass(d, {.Transparent, .Layer_Shell}, .Frosted), "no compositor blur")
	plain := d
	plain.backdrop = .None
	testing.expect(t, !surface_glass(plain, ALL_CAPS, .Frosted), "not asked for")
}

// The clear colour keeps text readable in every case: an opaque surface is
// the theme background; a glass panel is the panel material's translucent
// tint; Solid glass its own near-opaque tint; the tint made opaque when the
// compositor can't blur; and a transparent surface without a backdrop is
// cleared to nothing so the view can draw its own shape.
@(test)
surface_clear_is_translucent_only_when_glass_is_live :: proc(t: ^testing.T) {
	th := theme_dark()
	d := panel_desc()
	glass := surface_clear(&th, d, true)
	testing.expect_value(t, glass, th.material[.Frosted].panel.tint)
	testing.expect(t, glass.a < 1, "translucent")
	opaque := surface_clear(&th, d, false)
	testing.expect_value(t, opaque.a, f32(1))
	testing.expect(t, opaque.r == glass.r && opaque.g == glass.g && opaque.b == glass.b, "same colour, just opaque")
	win := d
	win.kind = .Window
	testing.expect_value(t, surface_clear(&th, win, true), th.material[.Frosted].window.tint)
	plain := d
	plain.transparent = false
	testing.expect_value(t, surface_clear(&th, plain, true), th.color.bg)
	shaped := d
	shaped.backdrop = .None
	testing.expect_value(t, surface_clear(&th, shaped, false), Color{})
	solid := th
	solid.glass = .Solid
	testing.expect_value(t, surface_clear(&solid, d, false).a, f32(0.97)) // the setting's near-opaque tint
	theme_opaque(&solid)
	testing.expect_value(t, surface_clear(&solid, d, false).a, f32(1)) // reduce transparency: nothing shows through
}

// A glass layer surface gets its bright line along the top edge, except
// where that edge is the screen's; windows and opaque surfaces get none.
@(test)
surface_highlight_runs_along_a_glass_bar_top_edge :: proc(t: ^testing.T) {
	th := theme_dark()
	top := panel_desc()
	testing.expect_value(t, surface_highlight(&th, top, true), Color{}) // attached to the top: its top edge is the screen's
	bottom := top
	bottom.layer.anchor = {.Bottom, .Left, .Right}
	testing.expect_value(t, surface_highlight(&th, bottom, true), th.material[.Frosted].panel.highlight)
	testing.expect(t, th.material[.Frosted].panel.highlight.a > 0)
	floating := top
	floating.layer.margin = {8, 8, 0, 8}
	testing.expect(t, surface_highlight(&th, floating, true).a > 0, "floating below the screen's edge")
	testing.expect_value(t, surface_highlight(&th, bottom, false), Color{}) // not glass
	win := bottom
	win.kind = .Window
	testing.expect_value(t, surface_highlight(&th, win, true), Color{})
}

// A window can ask for the whole screen, but the desktop decides: the ask
// and the answer are two different things and a view is built from the
// answer.
@(test)
asking_for_the_whole_screen_is_a_request_not_a_fact :: proc(t: ^testing.T) {
	window :: proc(fullscreen: bool) -> Surface_Desc(Sf_Msg) {
		return {tag = 1, kind = .Window, title = "Notes", size = {800, 600}, fullscreen = fullscreen}
	}
	// asking is a live change: the window is not reopened for it
	ch := surface_changes(window(false), window(true))
	testing.expect(t, .Fullscreen in ch, "the ask changed")
	testing.expect(t, ch - SURFACE_LIVE_CHANGES == {}, "and is applied to the open window")

	// it reaches the backend as part of the description
	p := surface_resolve(window(true), ALL_CAPS, "baldr.notes")
	testing.expect(t, p.fullscreen, "a window asks on the way up")

	// a layer surface (a bar, a dock) has no business asking
	layer := panel_desc()
	layer.fullscreen = true
	testing.expect(t, !surface_resolve(layer, ALL_CAPS, "baldr.panel").fullscreen, "only a window asks")

	// what a view reads is what the desktop did, which starts as "no" and
	// is not changed by asking
	ui: Ui(Sf_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	ui.surface = {tag = 1, kind = .Window}
	testing.expect(t, !ui.surface.fullscreen, "nothing has been granted yet")
	testing.expect(t, !ui.surface.maximized)
}

} // when ODIN_TEST