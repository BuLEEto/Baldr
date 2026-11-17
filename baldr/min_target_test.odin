package baldr

@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: they sit behind this `when` so an app does not pay
// for them (see canvas_test.odin).
when ODIN_TEST || #config(BALDR_TESTS, false) {

// A theme's smallest target, across and down, with a mouse as much as with
// a finger, for people who find small targets hard to hit. The
// controls grow to it with their content centred, a size the app fixed is
// kept, and what does not take a click stays its own size.

@(private = "file")
Mt_Msg :: union { int }

@(private = "file")
Mt_Nodes :: struct { btn, icon_btn, check, sl, fixed, row, plain: Node }

@(private = "file")
target_view :: proc(ui: ^Ui(Mt_Msg), disabled := false) -> (n: Mt_Nodes) {
	begin_view(ui)
	column(ui, padding = .lg, gap = .md, align = .Start)
	n.btn = button(ui, "Save", 1, disabled = disabled)
	n.icon_btn = button(ui, "Close", 2, icon = .X, icon_only = true, size = .Small)
	n.check = checkbox(ui, true, "Remember me")
	n.sl = slider(ui, 0.5, label = "Volume", width = 200)
	n.fixed = button(ui, "Tiny", 3)
	set_layout(&ui.tree, n.fixed, Layout_Props{height = 20}) // a height the app fixed
	n.row = list_row(ui, "Inbox", 4)
	n.plain = text(ui, "Plain words")
	end(ui)
	end_view(ui)
	frame(&ui.tree, {400, 700})
	return
}

@(private = "file")
target_set :: proc(ui: ^Ui(Mt_Msg), px: f32) {
	th := ui.tree.theme_asked
	th.min_target = px
	set_theme(&ui.tree, th)
}

@(private = "file")
target_centre :: proc(r: Rect) -> [2]f32 {
	return {r.x + r.w / 2, r.y + r.h / 2}
}

@(test)
controls_grow_to_the_themes_smallest_target :: proc(t: ^testing.T) {
	ui: Ui(Mt_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)

	n := target_view(&ui)
	h :: proc(ui: ^Ui(Mt_Msg), n: Node) -> f32 { return node_get(&ui.tree, n).abs.h }
	w :: proc(ui: ^Ui(Mt_Msg), n: Node) -> f32 { return node_get(&ui.tree, n).abs.w }
	testing.expect(t, h(&ui, n.btn) < 44, "a desktop button is compact")
	testing.expect_value(t, w(&ui, n.icon_btn), BUTTON_SMALL)
	testing.expect(t, h(&ui, n.check) < 44, "and a checkbox")
	testing.expect(t, h(&ui, n.sl) < 44, "and a slider")
	plain_h := h(&ui, n.plain)

	// The theme asks for 44. Laid out again *without* the view being built
	// again: layout keeps a node whose constraints did not change, so the
	// theme changing has to say so itself.
	target_set(&ui, 44)
	frame(&ui.tree, {400, 700})
	testing.expect_value(t, h(&ui, n.btn), 44)
	testing.expect_value(t, h(&ui, n.icon_btn), 44)
	testing.expect_value(t, w(&ui, n.icon_btn), 44) // across as well as down
	testing.expect_value(t, h(&ui, n.check), 44)
	testing.expect(t, h(&ui, n.row) >= 44, "a list row is a target too")
	testing.expect_value(t, h(&ui, n.fixed), 20) // the app's own height stands
	testing.expect_value(t, h(&ui, n.plain), plain_h) // and words take no click

	// The same after a build, which the run loop does after a theme is set.
	// A slider's height is its own, set as it is built, so it grows here.
	n = target_view(&ui)
	testing.expect_value(t, h(&ui, n.btn), 44)
	testing.expect_value(t, h(&ui, n.sl), 44)
	testing.expect_value(t, w(&ui, n.icon_btn), 44)
	testing.expect(t, h(&ui, n.row) >= 44, "the row asks for it itself")

	// What is inside stays where it was drawn: in the middle.
	icon := node_first(&ui.tree, n.icon_btn)
	ic, bc := target_centre(node_get(&ui.tree, icon).abs), target_centre(node_get(&ui.tree, n.icon_btn).abs)
	testing.expectf(t, abs(ic.x - bc.x) < 0.51 && abs(ic.y - bc.y) < 0.51, "the icon is centred: %v in %v", ic, bc)
	label := node_first(&ui.tree, n.btn)
	lc, sc := target_centre(node_get(&ui.tree, label).abs), target_centre(node_get(&ui.tree, n.btn).abs)
	testing.expectf(t, abs(lc.y - sc.y) < 0.51, "the label is centred down the button: %v in %v", lc, sc)
	testing.expect(t, h(&ui, label) < 44, "the label itself does not grow")

	// Back to the toolkit's own sizes, again without a build.
	target_set(&ui, 0)
	frame(&ui.tree, {400, 700})
	testing.expect(t, h(&ui, n.btn) < 44, "compact again")
	testing.expect_value(t, w(&ui, n.icon_btn), BUTTON_SMALL)
}

// A disabled control keeps the size: a form's Save button that becomes
// available must not make its row jump. Disabling repaints a control
// without laying it out, so a minimum that left disabled ones out would make
// a control's size depend on whether something else had moved it.
@(test)
a_disabled_control_keeps_the_target_size :: proc(t: ^testing.T) {
	ui: Ui(Mt_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	target_set(&ui, 44)
	n := target_view(&ui, disabled = true)
	testing.expect_value(t, node_get(&ui.tree, n.btn).abs.h, 44)
	n = target_view(&ui, disabled = false)
	testing.expect_value(t, node_get(&ui.tree, n.btn).abs.h, 44)

	// …and the same with a touchscreen and no theme minimum.
	target_set(&ui, 0)
	set_touch(&ui.tree, true)
	n = target_view(&ui, disabled = true)
	testing.expect_value(t, node_get(&ui.tree, n.btn).abs.h, TOUCH_TARGET)
}

// A touchscreen still makes controls finger-tall, and a theme minimum
// larger than that wins; the touch rule stays a height.
@(test)
touch_and_the_theme_take_the_larger :: proc(t: ^testing.T) {
	ui: Ui(Mt_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	set_touch(&ui.tree, true)
	n := target_view(&ui)
	testing.expect_value(t, node_get(&ui.tree, n.btn).abs.h, TOUCH_TARGET)
	testing.expect_value(t, node_get(&ui.tree, n.icon_btn).abs.w, BUTTON_SMALL) // touch alone: height only
	target_set(&ui, 52)
	n = target_view(&ui)
	testing.expect_value(t, node_get(&ui.tree, n.btn).abs.h, 52)
	testing.expect_value(t, node_get(&ui.tree, n.icon_btn).abs.w, 52)
}

// A word made clickable grows to the target like any control, and its
// text is set in the middle of that height, as a button's label is, not at
// the top of a box mostly empty below it.
@(test)
a_clickable_text_is_centred_in_its_target :: proc(t: ^testing.T) {
	ui: Ui(Mt_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	build :: proc(ui: ^Ui(Mt_Msg), click: bool) -> (word, plain: Node) {
		begin_view(ui)
		column(ui, align = .Start)
		word = text(ui, "Forgot it?")
		// A modifier's setting stays until changed, so nil takes the click
		// away. Two calls, not a ternary: `Mt_Msg(9) if click else nil` is
		// an empty Mt_Msg, which is a click.
		if click { clickable(ui, word, Mt_Msg(9)) } else { clickable(ui, word, nil) }
		row(ui, align = .Stretch, height = 60) // stretched, and no target: stays at its top
		plain = text(ui, "Stretched")
		end(ui)
		end(ui)
		end_view(ui)
		frame(&ui.tree, {400, 300})
		return
	}
	drawn_y :: proc(ui: ^Ui(Mt_Msg), s: string) -> f32 {
		for c in draw_list(&ui.tree) do if dt, ok := c.(Draw_Text); ok && dt.str == s do return dt.pos.y
		return -1
	}
	word, _ := build(&ui, false)
	text_h := node_get(&ui.tree, word).abs.h
	target_set(&ui, 44)
	word, _ = build(&ui, false)
	testing.expect_value(t, node_get(&ui.tree, word).abs.h, text_h) // words that take no click keep their size

	// Made clickable on a later build, as an app's state can make it: it
	// becomes a target, so it is laid out again and grows.
	plain: Node
	word, plain = build(&ui, true)
	wd := node_get(&ui.tree, word)
	testing.expect_value(t, wd.abs.h, 44)
	testing.expectf(t, abs(drawn_y(&ui, "Forgot it?") - (wd.abs.y + (44 - text_h) / 2)) < 0.01,
		"its line sits in the middle: drawn at %v in %v", drawn_y(&ui, "Forgot it?"), wd.abs)
	pd := node_get(&ui.tree, plain)
	testing.expect(t, pd.abs.h > text_h, "the stretched text is taller than its line")
	testing.expect_value(t, drawn_y(&ui, "Stretched"), pd.abs.y) // …and still drawn from its top

	// No longer clickable: back to its own height and its own top.
	word, _ = build(&ui, false)
	wd = node_get(&ui.tree, word)
	testing.expect_value(t, wd.abs.h, text_h)
	testing.expect_value(t, drawn_y(&ui, "Forgot it?"), wd.abs.y)
}

} // when ODIN_TEST
