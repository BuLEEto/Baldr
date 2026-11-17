package baldr

@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: they sit behind this `when` so an app does not pay
// for them (see canvas_test.odin).
when ODIN_TEST || #config(BALDR_TESTS, false) {

// A window that is see-through only so one pane can be frosted:
// `transparent = true, backdrop = .Blur, backdrop_region = .Marked`, with
// `backdrop_area` on that pane. Every other pane paints an opaque
// background, so adapting the whole theme for glass would re-solve colours
// the app chose for a backdrop most of its window never sits on. What is on
// the marked node is solved for the wallpaper; what is not keeps the app's
// colours.

@(private = "file")
Gm_Msg :: union { int }

@(private = "file")
ROSE :: Color{0.72, 0.26, 0.43, 1} // an app's brand accent, as adjust_theme would leave it

@(private = "file")
gm_tree :: proc(t: ^Tree, marked: bool) {
	tree_init(t)
	th := theme_light()
	th.color.primary = ROSE
	t.backdrop_marked = marked
	t.glass = {on = true, role = .Window, known = true, backdrop = Backdrop_Range{0.002, 0.01, 0.03}} // a dark wallpaper
	tree_theme(t, th)
}

// The window's own theme keeps what the app set, and a separate one is
// adapted for the marked pane.
@(test)
a_marked_glass_window_keeps_the_colours_the_app_set :: proc(t: ^testing.T) {
	marked: Tree
	gm_tree(&marked, true)
	defer tree_destroy(&marked)

	testing.expect(t, marked.glass_theme_ok, "a theme was adapted for the glass")
	testing.expect_value(t, marked.theme.color.primary, ROSE) // …and the window kept the app's

	// The whole-window case still adapts the tree: there every pane really is
	// over the wallpaper.
	whole: Tree
	gm_tree(&whole, false)
	defer tree_destroy(&whole)
	testing.expect(t, !whole.glass_theme_ok, "nothing separate to adapt")
	testing.expect(t, whole.theme.color.primary != ROSE,
		"a window that is all glass is still solved for what is behind it")

	// And the two agree about the glass itself: what the marked pane gets is
	// what the whole window gets.
	testing.expect_value(t, marked.glass_theme.color.primary, whole.theme.color.primary)
}

// The marked node's own subtree builds with the adapted theme, and its
// siblings do not: the sidebar reads over the wallpaper, the chat column
// keeps the brand.
@(test)
what_is_built_on_a_marked_node_uses_the_glass_theme :: proc(t: ^testing.T) {
	ui: Ui(Gm_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	tr := &ui.tree
	th := theme_light()
	th.color.primary = ROSE
	tr.backdrop_marked = true
	tr.glass = {on = true, role = .Window, known = true, backdrop = Backdrop_Range{0.002, 0.01, 0.03}}
	tree_theme(tr, th)
	if !tr.glass_theme_ok do testing.fail_now(t, "no glass theme")
	adapted := tr.glass_theme.color.primary

	inside, outside: Color
	begin_view(&ui)
	row(&ui, padding = .none)
	{
		pane := column(&ui, padding = .md, key = 1)
		backdrop_area(&ui, pane) // this pane is the glass
		inside = ui.tree.theme.color.primary
		text(&ui, "sidebar", key = 2)
		end(&ui)
	}
	{
		column(&ui, padding = .md, key = 3)
		outside = ui.tree.theme.color.primary
		text(&ui, "chat", key = 4)
		end(&ui)
	}
	end(&ui)
	end_view(&ui)
	frame(tr, {800, 600})

	testing.expect_value(t, inside, adapted)  // solved for the wallpaper
	testing.expect_value(t, outside, ROSE)    // the app's own
	testing.expect_value(t, tr.theme.color.primary, ROSE) // …and the theme is back after the scope
}

// A pane painting its own ground must read its material's tint after
// backdrop_area: before it, `ui.theme` is the deliberately unadapted tree
// theme, so the ground would be unsolved under solved text, and nothing says
// so.
@(test)
a_panes_own_ground_must_be_read_inside_the_scope :: proc(t: ^testing.T) {
	ui: Ui(Gm_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	tr := &ui.tree
	th := theme_light()
	th.color.primary = ROSE
	tr.backdrop_marked = true
	tr.glass = {on = true, role = .Window, known = true, backdrop = Backdrop_Range{0.002, 0.01, 0.03}}
	tree_theme(tr, th)
	if !tr.glass_theme_ok do testing.fail_now(t, "no glass theme")

	lvl := tr.theme.glass
	unsolved := tr.theme.material[lvl].window.tint
	solved := tr.glass_theme.material[lvl].window.tint
	testing.expect(t, solved.a > unsolved.a,
		"the glass theme's tint was raised for the wallpaper and the window's was not")

	before, inside, after: f32
	begin_view(&ui)
	pane := column(&ui, padding = .md, key = 1)
	before = ui.tree.theme.material[lvl].window.tint.a // what a pane reading too early gets
	backdrop_area(&ui, pane)
	inside = ui.tree.theme.material[lvl].window.tint.a // …and what its text is solved against
	text(&ui, "on the glass", key = 2)
	end(&ui)
	after = ui.tree.theme.material[lvl].window.tint.a
	end_view(&ui)
	frame(tr, {800, 600})

	testing.expect_value(t, before, unsolved.a) // the trap
	testing.expect_value(t, inside, solved.a)   // read after the call: the solved one
	testing.expect_value(t, after, unsolved.a)  // and the scope gives it back
	testing.expect(t, before != inside, "which is why reading it too early is a bug that shows as bad contrast")
}

// Turning the mark off gives the scope nothing to swap, so an app that
// stops marking a pane goes back to one theme everywhere.
@(test)
an_unmarked_pane_builds_with_the_windows_theme :: proc(t: ^testing.T) {
	ui: Ui(Gm_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	tr := &ui.tree
	th := theme_light()
	th.color.primary = ROSE
	tr.backdrop_marked = true
	tr.glass = {on = true, role = .Window, known = true, backdrop = Backdrop_Range{0.002, 0.01, 0.03}}
	tree_theme(tr, th)

	seen: Color
	begin_view(&ui)
	pane := column(&ui, padding = .md, key = 1)
	backdrop_area(&ui, pane, on = false)
	seen = ui.tree.theme.color.primary
	end(&ui)
	end_view(&ui)
	frame(tr, {800, 600})
	testing.expect_value(t, seen, ROSE)
}

}
