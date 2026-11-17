package baldr

@(require) import "core:strings"
@(require) import "core:testing"
@(require) import "baldr:platform"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: they sit behind this `when` so an app does not pay
// for them. ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh
// check look inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// A disabled tree row, glass that follows the compositor, the desktop's
// preferences under an app's own theme, and toggle buttons.


@(private = "file")
RequestsStep8_RMsg :: enum { None, Pick, Toggle }

@(private = "file")
node_named :: proc(t: ^Tree, root: Node, name: string) -> Node {
	d := node_get(t, root)
	if d == nil do return NODE_NONE
	if d.access.name == name do return root
	for c := d.first; c != NODE_NONE; c = node_get(t, c).next {
		if found := node_named(t, c, name); found != NODE_NONE do return found
	}
	return NODE_NONE
}

@(private = "file")
palette :: proc(ui: ^Ui(RequestsStep8_RMsg)) {
	set_viewport(&ui.tree, {400, 300})
	begin_view(ui)
	column(ui)
	tree_view(ui, label = "Commands", key = 1)
	tree_item(ui, "Open", RequestsStep8_RMsg.Pick, icon = .Check, tag = 1)
	tree_item(ui, "Rename", RequestsStep8_RMsg.Pick, icon = .Check, disabled = true, tag = 2)
	end(ui)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {400, 300})
}

@(private = "file")
text_alpha :: proc(t: ^Tree, s: string) -> f32 {
	for c in draw_list(t) do if q, ok := c.(Draw_Text); ok && q.str == s do return q.color.a
	return -1
}

@(private = "file")
icon_alpha :: proc(t: ^Tree, row: Node) -> f32 {
	r := node_get(t, row).abs
	for c in draw_list(t) do if q, ok := c.(Draw_Icon); ok && q.icon == .Check && q.pos.y >= r.y && q.pos.y < r.y + r.h do return q.color.a
	return -1
}

@(private = "file")
row_fill :: proc(t: ^Tree, row: Node) -> f32 {
	r := node_get(t, row).abs
	for c in draw_list(t) do if q, ok := c.(Draw_Rect); ok && q.rect == r do return q.color.a
	return 0
}

@(test)
a_disabled_tree_row_is_dimmed_and_shows_no_hover :: proc(t: ^testing.T) {
	ui: Ui(RequestsStep8_RMsg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	th := theme_light()
	th.motion.reduce = true // state layers land at once
	set_theme(&ui.tree, th)
	palette(&ui)
	open := node_named(&ui.tree, ui.root, "Open")
	rename := node_named(&ui.tree, ui.root, "Rename")
	da := ui.tree.theme.state.disabled_alpha
	testing.expectf(t, abs(text_alpha(&ui.tree, "Rename") - text_alpha(&ui.tree, "Open") * da) < 0.01, "the label is dimmed (%v vs %v)", text_alpha(&ui.tree, "Rename"), text_alpha(&ui.tree, "Open"))
	testing.expectf(t, abs(icon_alpha(&ui.tree, rename) - icon_alpha(&ui.tree, open) * da) < 0.01, "the icon is dimmed (%v vs %v)", icon_alpha(&ui.tree, rename), icon_alpha(&ui.tree, open))
	now := 1000.0
	for row in ([]Node{open, rename}) {
		rd := node_get(&ui.tree, row)
		pointer_move(&ui, {rd.abs.x + 40, rd.abs.y + rd.abs.h / 2})
		now += 500
		ui_tick(&ui, now)
		palette(&ui)
		now += 500
		ui_tick(&ui, now)
		frame(&ui.tree, {400, 300})
		if row == open {
			testing.expect(t, row_fill(&ui.tree, row) > 0, "an enabled row shows hover")
		} else {
			testing.expectf(t, row_fill(&ui.tree, row) == 0, "a disabled row shows none (%v)", row_fill(&ui.tree, row))
		}
	}
}

@(private = "file")
RequestsStep8_RState :: struct {}

// Glass and preferences through the run loop's apply_theme, which Ev_Caps and
// Ev_Theme call.
@(test)
glass_and_preferences_follow_the_desktop :: proc(t: ^testing.T) {
	log: [dynamic]platform.Backdrop
	defer delete(log)
	backend := platform.Backend{caps = {.Transparent, .Backdrop_Blur}, data = &log}
	backend.surface_set_backdrop = proc(b: ^platform.Backend, s: platform.Surface, backdrop: platform.Backdrop) {
		append((^[dynamic]platform.Backdrop)(b.data), backdrop)
	}
	rt: Runtime(RequestsStep8_RState, RequestsStep8_RMsg)
	rt.backend = &backend
	rt.theme = theme_dark()
	defer delete(rt.ctxs)
	c := new(Surface_Ctx(RequestsStep8_RMsg))
	defer free(c)
	ui_init(&c.ui)
	defer ui_destroy(&c.ui)
	c.desc = {transparent = true, backdrop = .Blur}
	append(&rt.ctxs, c)

	apply_theme(&rt)
	testing.expect(t, c.ui.surface.glass && len(log) == 1 && log[0] == .Blur, "blur offered: glass")
	testing.expect_value(t, c.ui.tree.theme.name, rt.theme.name)
	glass_clear := c.fc.clear

	backend.caps -= {.Backdrop_Blur} // Ev_Caps: the compositor stopped blurring
	apply_theme(&rt)
	testing.expect(t, !c.ui.surface.glass && log[len(log) - 1] == .None, "no blur: opaque")
	testing.expect(t, c.fc.clear != glass_clear, "and the clear colour with it")
	backend.caps += {.Backdrop_Blur}
	apply_theme(&rt)
	testing.expect(t, c.ui.surface.glass && log[len(log) - 1] == .Blur, "blur back: glass again")

	mine := theme_light()
	mine.name = "Mine"
	mine.glass = .Clear
	set_theme(&c.ui.tree, mine) // the app's own theme, from its view
	rt.prefs = {reduce_transparency = true, reduce_motion = true} // Ev_Theme: the desktop asks for less
	apply_theme(&rt)
	th := c.ui.tree.theme
	testing.expect_value(t, th.name, "Mine") // the app's theme stays
	testing.expect(t, th.glass == .Solid && th.motion.reduce, "with the desktop's preferences folded in")
	testing.expect(t, !c.ui.surface.glass)
	testing.expect_value(t, c.fc.clear.a, f32(1)) // nothing shows through
	set_theme(&c.ui.tree, mine) // set again from the view: still folded
	testing.expect(t, c.ui.tree.theme.glass == .Solid && c.ui.tree.theme.motion.reduce)
	rt.prefs = {}
	apply_theme(&rt)
	testing.expect(t, c.ui.tree.theme.glass == .Clear && !c.ui.tree.theme.motion.reduce, "preferences off: the theme as the app set it")
	testing.expect(t, c.ui.surface.glass)
}

@(private = "file")
toolbar :: proc(ui: ^Ui(RequestsStep8_RMsg), preview: Maybe(bool), variant: Button_Variant = .Ghost) -> Node {
	set_viewport(&ui.tree, {400, 100})
	begin_view(ui)
	row(ui)
	b := button(ui, "Preview", RequestsStep8_RMsg.Toggle, variant = variant, icon = .Check, icon_only = true, pressed = preview)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {400, 100})
	return b
}

@(test)
a_toggle_button_says_whether_it_is_on :: proc(t: ^testing.T) {
	ui: Ui(RequestsStep8_RMsg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	b := toolbar(&ui, true)
	d := node_get(&ui.tree, b)
	testing.expect_value(t, d.access.role, Role.Toggle_Button)
	testing.expect(t, .Pressed in d.access.states)
	testing.expect_value(t, d.style.bg, ui.tree.theme.color.primary_container) // the tonal fill
	testing.expect(t, strings.contains(access_dump(&ui.tree), "Toggle_Button"))
	d = node_get(&ui.tree, toolbar(&ui, false))
	testing.expect_value(t, d.access.role, Role.Toggle_Button)
	testing.expect(t, .Pressed not_in d.access.states)
	testing.expect(t, d.style.bg.a == 0, "off: the ghost look")
	d = node_get(&ui.tree, toolbar(&ui, false, .Primary))
	testing.expect_value(t, d.style.bg, ui.tree.theme.color.surface_high) // a filled toggle goes quiet when off
	d = node_get(&ui.tree, toolbar(&ui, true, .Primary))
	testing.expect_value(t, d.style.bg, ui.tree.theme.color.primary)
	testing.expect_value(t, node_get(&ui.tree, toolbar(&ui, nil)).access.role, Role.Button) // not a toggle
	b = toolbar(&ui, true)
	set_focus(&ui.tree, b, true)
	clear(&ui.msgs)
	testing.expect(t, key_event(&ui, .Space, true, {}))
	testing.expect(t, len(ui.msgs) == 1 && ui.msgs[0] == .Toggle)
	testing.expect(t, lint(&ui.tree) == 0)
}

} // when ODIN_TEST