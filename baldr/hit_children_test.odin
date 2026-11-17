package baldr

@(require) import "core:testing"

// A container with no child under the point is itself the hit, so a `row`
// the canvas's width that only centres a small pill over the picture (a
// sibling of the canvas in a `stack`) would swallow presses and motion
// across its whole strip. `set_hit_children` lets a container's own space
// pass the pointer through while its children still take it, as the overlay
// root does. `Hit_Transparent` and `inert` cannot answer it: both take the
// children out with the parent.
when ODIN_TEST || #config(BALDR_TESTS, false) {

@(private = "file")
Hc_Msg :: union { int }

@(private = "file")
HC_VIEW :: [2]f32{1280, 690}

// A canvas filling the window, and over it a full-width row centring a
// pill. `through` is whether the row lets the pointer past.
@(private = "file")
hc_build :: proc(ui: ^Ui(Hc_Msg), through: bool) -> (canvas, bar, pill: Node) {
	set_viewport(&ui.tree, HC_VIEW)
	begin_view(ui)
	stack(ui, flex = 1)
	outer := ui.scopes[len(ui.scopes) - 1].node
	{
		box(ui, width = HC_VIEW.x, height = HC_VIEW.y, key = 1) // the picture, fitted to the window

		// the centring row, 40 px tall at the bottom, the width of the canvas
		row(ui, width = HC_VIEW.x, height = 40, justify = .Center, offset = {0, 650}, key = 2)
		bar = ui.scopes[len(ui.scopes) - 1].node
		set_hit_children(&ui.tree, bar, through)
		box(ui, width = 180, height = 32, key = 3) // the pill
		end(ui)
	}
	end(ui)
	end_view(ui)
	frame(&ui.tree, HC_VIEW)
	od := node_get(&ui.tree, outer)
	canvas = od.first if od != nil else NODE_NONE // the picture, built first
	if bd := node_get(&ui.tree, bar); bd != nil do pill = bd.first
	return
}

// Without it the row is the hit everywhere it reaches, the whole width; this
// keeps the next test from passing vacuously.
@(test)
r171_a_centring_row_otherwise_swallows_the_picture :: proc(t: ^testing.T) {
	ui: Ui(Hc_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	_, bar, _ := hc_build(&ui, false)

	// left and right of the pill, in window coordinates
	testing.expectf(t, hit_test(&ui.tree, {60, 670}) == bar,
		"left of the pill the row takes it (%v, row is %v)", hit_test(&ui.tree, {60, 670}), bar)
	testing.expect(t, hit_test(&ui.tree, {760, 670}) == bar, "and right of it too")
}

// With it, the row's own space is the picture's again: either side of the
// pill reaches the canvas.
@(test)
r171_a_row_can_let_the_pointer_through_to_the_picture :: proc(t: ^testing.T) {
	ui: Ui(Hc_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	canvas, bar, _ := hc_build(&ui, true)

	left := hit_test(&ui.tree, {60, 670})
	right := hit_test(&ui.tree, {760, 670})
	testing.expectf(t, left == canvas, "left of the pill reaches the picture (%v, want %v)", left, canvas)
	testing.expectf(t, right == canvas, "right of the pill too (%v, want %v)", right, canvas)
	testing.expect(t, left != bar && right != bar, "and never the row itself")
	// and the picture was always reachable away from the bar
	testing.expect(t, hit_test(&ui.tree, {60, 300}) == canvas, "the middle of the picture is unchanged")
}

// The point of the row is still to lay the pill out and have it clickable:
// only the container's *own* space lets the pointer through.
@(test)
r171_the_control_inside_still_takes_the_pointer :: proc(t: ^testing.T) {
	ui: Ui(Hc_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	canvas, _, pill := hc_build(&ui, true)
	d := node_get(&ui.tree, pill)
	testing.expect(t, d != nil, "the pill is built")
	mid := [2]f32{d.abs.x + d.abs.w / 2, d.abs.y + d.abs.h / 2}
	got := hit_test(&ui.tree, mid)
	testing.expectf(t, got == pill, "the pill itself is hit (%v, want %v)", got, pill)
	testing.expect(t, got != canvas, "the picture does not steal it back")
	// centred, which is what the row was for
	testing.expectf(t, abs((d.abs.x + d.abs.w / 2) - HC_VIEW.x / 2) < 1,
		"and it is still centred by ordinary layout (%.0f)", d.abs.x + d.abs.w / 2)
}

// It is a hit-testing change and nothing else: the node lays out, draws and
// keeps its place for assistive technology. `inert` is the one that takes a
// subtree out of all three.
@(test)
r171_letting_the_pointer_through_is_not_inert :: proc(t: ^testing.T) {
	ui: Ui(Hc_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	_, bar, pill := hc_build(&ui, true)
	d := node_get(&ui.tree, bar)
	testing.expect(t, d != nil && .Inert not_in d.flags, "it is not inert")
	testing.expect(t, .Hidden not_in d.flags, "nor hidden")
	testing.expectf(t, d.abs.w == HC_VIEW.x, "it still has its full width to lay out in (%.0f)", d.abs.w)
	p := node_get(&ui.tree, pill)
	testing.expect(t, p != nil && p.abs.w == 180, "and its child still has its size")
}

// Turning it off puts the row back to taking the pointer, so an app can pass
// the state every build as the other setters ask.
@(test)
r171_it_can_be_turned_off_again :: proc(t: ^testing.T) {
	ui: Ui(Hc_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	_, bar, _ := hc_build(&ui, true)
	testing.expect(t, hit_test(&ui.tree, {60, 670}) != bar, "through while it is on")

	_, bar2, _ := hc_build(&ui, false) // the same node, reconciled, now opaque
	testing.expect(t, bar2 == bar, "it is the same row across the rebuild")
	testing.expect(t, hit_test(&ui.tree, {60, 670}) == bar, "and it takes the pointer again")
}

}
