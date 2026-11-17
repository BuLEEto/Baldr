package baldr

@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: they sit behind this `when` so an app does not pay
// for them (see canvas_test.odin).
when ODIN_TEST || #config(BALDR_TESTS, false) {

// A tooltip is drawn over whatever is near its anchor, so a press has to
// reach *that*, not the tip. It matters whenever the pointer does not move
// between hover and press — every touch tap, every fast flick where the move
// and the press arrive together — since moving off the anchor first would
// take the tooltip down.

@(private = "file")
Th_Msg :: union { int }

@(test)
a_tooltip_never_takes_a_press_meant_for_what_is_under_it :: proc(t: ^testing.T) {
	ui: Ui(Th_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)

	// two rows a tooltip's height apart, as links on consecutive lines are
	first, second: Node
	build :: proc(ui: ^Ui(Th_Msg), show_tip: bool) -> (a, b: Node) {
		set_viewport(&ui.tree, {400, 300})
		begin_view(ui)
		column(ui, padding = .none, gap = .none)
		a = button(ui, "one", Th_Msg(1), key = 1)
		b = button(ui, "two", Th_Msg(2), key = 2)
		tooltip(ui, a, "https://example.com/a-long-target-that-covers-the-next-line")
		end(ui)
		end_view(ui)
		frame(&ui.tree, {400, 300})
		return
	}
	first, second = build(&ui, false)

	// rest on the first until its tooltip is up
	db := node_get(&ui.tree, second)
	if db == nil do testing.fail_now(t, "no second button")
	da := node_get(&ui.tree, first)
	pointer_move(&ui, {da.abs.x + 10, da.abs.y + 5})
	// the first tick notes the hover and starts the clock; only a later one
	// past the delay puts the tooltip up
	tooltip_tick(&ui, ui.tree.now_ms)
	ui.tree.now_ms += TOOLTIP_DELAY_MS + 1
	tooltip_tick(&ui, ui.tree.now_ms)
	first, second = build(&ui, true)
	if !testing.expect(t, ui.tip_anchor == first, "the tooltip is showing") do return

	// it really is over the second button — otherwise this proves nothing
	tip := NODE_NONE
	for n, r in ui.tree.overlay_rules do if r.anchor == first do tip = n
	if !testing.expect(t, tip != NODE_NONE, "the tooltip has a node") do return
	td := node_get(&ui.tree, tip)
	db = node_get(&ui.tree, second)
	overlaps := td != nil && td.abs.y < db.abs.y + db.abs.h && td.abs.y + td.abs.h > db.abs.y &&
		td.abs.x < db.abs.x + db.abs.w && td.abs.x + td.abs.w > db.abs.x
	if !testing.expect(t, overlaps, "the tooltip covers the second button, as the assistant app's did") do return

	// a press where they overlap reaches the button, not the tip
	at := [2]f32{max(td.abs.x, db.abs.x) + 2, max(td.abs.y, db.abs.y) + 2}
	hit := hit_test(&ui.tree, at)
	testing.expect(t, hit != tip, "the tooltip is not what the pointer finds there")
	testing.expect(t, node_within(&ui.tree, hit, second) || hit == second,
		"…the button under it is")
}

}
