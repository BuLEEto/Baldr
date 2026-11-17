package baldr

@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too; behind this `when` an app does not pay for them.
// ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh check look
// inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

@(private = "file")
Zoom_ZMsg :: struct { by: f32, tag: u64 }

@(test)
zoom_routes_ctrl_wheel_to_the_nearest_zoomable :: proc(t: ^testing.T) {
	ui: Ui(Zoom_ZMsg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	set_viewport(&ui.tree, {400, 300})
	begin_view(&ui)
	column(&ui, gap = .sm)
	pic := box(&ui, width = 200, height = 100)
	zoomable(&ui, pic, proc(e: Ev(f32)) -> Zoom_ZMsg { return Zoom_ZMsg{e.value, e.tag} })
	plain := box(&ui, width = 200, height = 100)
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {400, 300})
	pd := node_get(&ui.tree, pic)
	inside := [2]f32{pd.abs.x + 10, pd.abs.y + 10}
	testing.expect(t, zoom_event(&ui, inside, {0, -48}), "a wheel notch up over the picture")
	testing.expect_value(t, len(ui.msgs), 1)
	testing.expect_value(t, ui.msgs[0].by, 48) // positive = zoom in
	qd := node_get(&ui.tree, plain)
	testing.expect(t, !zoom_event(&ui, {qd.abs.x + 10, qd.abs.y + 10}, {0, 48}), "nothing over a plain box: the wheel scrolls as usual")
	testing.expect_value(t, len(ui.msgs), 1)
}

} // when ODIN_TEST