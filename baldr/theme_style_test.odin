package baldr

@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: they sit behind this `when` so an app does not pay
// for them (see canvas_test.odin).
when ODIN_TEST || #config(BALDR_TESTS, false) {

// Component styles and density, through the builders: a style field set on
// the theme reaches what is drawn, density moves control heights by a fixed
// step and never below the target size, and a subtree can carry a theme of
// its own for one control.

@(private = "file")
Ts_Msg :: union { int }

@(private = "file")
STYLE_RED :: Color{0.8, 0.1, 0.1, 1}

@(private = "file")
style_view :: proc(ui: ^Ui(Ts_Msg)) -> (btn, row: Node) {
	begin_view(ui)
	column(ui, align = .Start)
	btn = button(ui, "Save", 1)
	row = list_row(ui, "Inbox", 2)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {400, 300})
	return
}

@(private = "file")
style_theme :: proc(ui: ^Ui(Ts_Msg), change: proc(th: ^Theme)) {
	th := ui.tree.theme_asked
	change(&th)
	set_theme(&ui.tree, th)
}

@(test)
a_button_takes_its_style_from_the_theme :: proc(t: ^testing.T) {
	ui: Ui(Ts_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	btn, _ := style_view(&ui)
	testing.expect_value(t, node_get(&ui.tree, btn).style.radius, ui.tree.theme.radius.md) // nil: the radius ladder's

	style_theme(&ui, proc(th: ^Theme) {
		th.button.radius = 0 // a real value, not "unset": square corners
		th.button.primary.fill = STYLE_RED
	})
	btn, _ = style_view(&ui)
	d := node_get(&ui.tree, btn)
	testing.expect_value(t, d.style.radius, 0)
	testing.expect_value(t, d.style.bg, STYLE_RED)
	testing.expect(t, d.style.bg2 != {}, "the gradient follows the new fill")

	// A global token still flows to a field the style leaves nil.
	style_theme(&ui, proc(th: ^Theme) {
		th.button = {}
		th.radius.md = 2
	})
	btn, _ = style_view(&ui)
	testing.expect_value(t, node_get(&ui.tree, btn).style.radius, 2)
}

@(test)
density_moves_control_heights_by_a_step :: proc(t: ^testing.T) {
	ui: Ui(Ts_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	btn, row := style_view(&ui)
	b0, r0 := node_get(&ui.tree, btn).abs.h, node_get(&ui.tree, row).abs.h

	style_theme(&ui, proc(th: ^Theme) { th.density = -1 })
	btn, row = style_view(&ui)
	testing.expect_value(t, node_get(&ui.tree, btn).abs.h, b0 - DENSITY_STEP)
	testing.expect_value(t, node_get(&ui.tree, row).abs.h, r0 - DENSITY_STEP)

	style_theme(&ui, proc(th: ^Theme) { th.density = 1 })
	btn, row = style_view(&ui)
	testing.expect_value(t, node_get(&ui.tree, btn).abs.h, b0 + DENSITY_STEP)
	testing.expect_value(t, node_get(&ui.tree, row).abs.h, r0 + DENSITY_STEP)

	// Compact never goes below the theme's smallest target.
	style_theme(&ui, proc(th: ^Theme) {
		th.density = -1
		th.min_target = 44
	})
	btn, _ = style_view(&ui)
	testing.expect_value(t, node_get(&ui.tree, btn).abs.h, 44)
}

@(test)
menus_follow_the_popover_style :: proc(t: ^testing.T) {
	th := theme_light()
	testing.expect_value(t, menu_look(&th).fill, popover_look(&th).fill)
	th.popover.fill = STYLE_RED
	th.popover.radius = 3
	testing.expect_value(t, menu_look(&th).fill, STYLE_RED) // a menu is a popover
	testing.expect_value(t, menu_look(&th).radius, 3)
	th.menu.fill = Color{0, 0, 1, 1}
	testing.expect_value(t, menu_look(&th).fill, Color{0, 0, 1, 1}) // its own style wins
}

// One control styled apart from the theme, as Flutter's Theme widget does
// it: the subtree gets a theme of its own and everything else keeps the
// window's.
@(test)
a_subtree_can_style_one_control :: proc(t: ^testing.T) {
	ui: Ui(Ts_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	build :: proc(ui: ^Ui(Ts_Msg)) -> (inside, outside: Node) {
		begin_view(ui)
		column(ui, align = .Start)
		area := row(ui)
		own := ui.tree.theme
		own.button.radius = 0
		own.button.primary.fill = STYLE_RED
		theme_area(ui, area, own)
		inside = button(ui, "Delete", 1)
		end(ui)
		outside = button(ui, "Save", 2)
		end(ui)
		end_view(ui)
		frame(&ui.tree, {400, 300})
		return
	}
	inside, outside := build(&ui)
	testing.expect_value(t, node_get(&ui.tree, inside).style.radius, 0)
	testing.expect_value(t, node_get(&ui.tree, inside).style.bg, STYLE_RED)
	testing.expect_value(t, node_get(&ui.tree, outside).style.radius, ui.tree.theme.radius.md)
	testing.expect(t, node_get(&ui.tree, outside).style.bg != STYLE_RED, "the window's theme outside the subtree")
}

// A text size a style sets is at text scale 1 and follows the desktop's text
// size, as the type scale's do.
@(test)
a_style_text_size_follows_the_text_scale :: proc(t: ^testing.T) {
	ui: Ui(Ts_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	small :: proc(ui: ^Ui(Ts_Msg)) -> Node {
		begin_view(ui)
		column(ui, align = .Start)
		b := button(ui, "Tiny", 1, size = .Small)
		end(ui)
		end_view(ui)
		frame(&ui.tree, {400, 300})
		return node_first(&ui.tree, b)
	}
	style_theme(&ui, proc(th: ^Theme) { th.button.small.text.size = 15 })
	lbl := small(&ui)
	testing.expect_value(t, node_get(&ui.tree, lbl).kind.(Text_Kind).size, 15)
	set_text_scale(&ui.tree, 2)
	lbl = small(&ui)
	testing.expect_value(t, node_get(&ui.tree, lbl).kind.(Text_Kind).size, 30)
}

} // when ODIN_TEST
