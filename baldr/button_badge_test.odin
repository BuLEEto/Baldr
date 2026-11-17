package baldr

@(require) import "core:testing"

// Test files are part of the package, so without this `when` every program
// that imports Baldr would type-check the whole suite too. ODIN_TEST is set
// by `odin test`; BALDR_TESTS lets ./build.sh check look inside.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// A badge at the corner of a button's icon, such as a shell's notification bell.


@(private = "file")
ButtonBadge_BMsg :: union { int }

// bell: a 36 px bar holding one icon-only button, with `badge` set on it.
@(private = "file")
bell :: proc(ui: ^Ui(ButtonBadge_BMsg), badge: Maybe(Button_Badge), disabled := false) -> Node {
	begin_view(ui)
	row(ui, height = 36, padding = .xs, align = .Center)
	b := button(ui, "Notifications", ButtonBadge_BMsg(1), variant = .Ghost, icon = .Bell, icon_only = true, disabled = disabled)
	if v, ok := badge.?; ok do button_options(ui, b, badge = v)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {200, 36})
	return b
}

// badge_drawn: the badge's pill or dot inside button `b` (a filled rect as round as it is tall, no taller
// than a pill), and the text drawn right after it.
@(private = "file")
badge_drawn :: proc(ui: ^Ui(ButtonBadge_BMsg), b: Node) -> (rect: Rect, color: Color, text: Draw_Text, ok: bool) {
	bd := node_get(&ui.tree, b)
	cmds := draw_list(&ui.tree)
	for c, i in cmds {
		r, is_rect := c.(Draw_Rect)
		if !is_rect || r.color.a == 0 || r.rect.h <= 0 || r.rect.h > BUTTON_BADGE_HEIGHT || abs(r.radius - r.rect.h / 2) > 0.01 do continue
		if r.rect.x < bd.abs.x - 0.01 || r.rect.y < bd.abs.y - 0.01 || r.rect.x + r.rect.w > bd.abs.x + bd.abs.w + 0.01 || r.rect.y + r.rect.h > bd.abs.y + bd.abs.h + 0.01 do continue
		rect, color, ok = r.rect, r.color, true
		if i + 1 < len(cmds) {
			if tx, is_text := cmds[i + 1].(Draw_Text); is_text do text = tx
		}
		return
	}
	return
}

@(private = "file")
icon_of :: proc(ui: ^Ui(ButtonBadge_BMsg), b: Node) -> Rect {
	for ch := node_get(&ui.tree, b).first; ch != NODE_NONE; ch = node_get(&ui.tree, ch).next {
		if cd := node_get(&ui.tree, ch); Control_Part(cd.key) == .Icon do return cd.abs
	}
	return {}
}

// A badge takes no room. A dot sits centred on the icon's top end corner in
// the accent; a count sits there in a pill as tall as BUTTON_BADGE_HEIGHT,
// its text centred in the accent's text colour, and a longer count is wider,
// still inside the button.
@(test)
a_button_badge_takes_no_room :: proc(t: ^testing.T) {
	plain: Ui(ButtonBadge_BMsg)
	ui_init(&plain)
	defer ui_destroy(&plain)
	pb := bell(&plain, nil)
	_, _, _, none := badge_drawn(&plain, pb)
	testing.expect(t, !none, "no badge until one is set")

	dot: Ui(ButtonBadge_BMsg)
	ui_init(&dot)
	defer ui_destroy(&dot)
	b := bell(&dot, Button_Badge{dot = true})
	testing.expect_value(t, node_get(&dot.tree, b).abs, node_get(&plain.tree, pb).abs) // no room taken
	r, c, _, ok := badge_drawn(&dot, b)
	ic := icon_of(&dot, b)
	testing.expect(t, ok, "the dot is drawn")
	testing.expect_value(t, r, Rect{ic.x + ic.w - BUTTON_BADGE_DOT / 2, ic.y - BUTTON_BADGE_DOT / 2, BUTTON_BADGE_DOT, BUTTON_BADGE_DOT})
	testing.expect_value(t, c, dot.tree.theme.color.primary)

	count: Ui(ButtonBadge_BMsg)
	ui_init(&count)
	defer ui_destroy(&count)
	b = bell(&count, Button_Badge{text = "3"})
	bd := node_get(&count.tree, b).abs
	tx: Draw_Text
	r, c, tx, ok = badge_drawn(&count, b)
	testing.expect(t, ok && tx.str == "3", "a count in a pill")
	testing.expect_value(t, r.h, BUTTON_BADGE_HEIGHT)
	testing.expect_value(t, c, count.tree.theme.color.primary)
	testing.expect_value(t, tx.color, count.tree.theme.color.on_primary)
	testing.expect_value(t, tx.weight, Font_Weight.Semibold)
	m := count.tree.measure_text(&count.tree, "3", BUTTON_BADGE_TEXT, 0, .Semibold, false, 0, false)
	testing.expect_value(t, tx.pos, [2]f32{r.x + r.w / 2, r.y + r.h / 2} - m / 2) // centred
	narrow := r.w
	b = bell(&count, Button_Badge{text = "99+"})
	r, _, tx, ok = badge_drawn(&count, b)
	testing.expectf(t, ok && tx.str == "99+" && r.w > narrow, "a longer count is wider: %v", r.w)
	testing.expect(t, r.x + r.w <= bd.x + bd.w + 0.01 && r.y >= bd.y - 0.01, "and stays inside the button")
}

// A badge added to a button on screen grows in over motion.fast and shrinks
// away when it goes; under reduce motion both are at once.
@(test)
a_button_badge_comes_and_goes_smoothly :: proc(t: ^testing.T) {
	ui: Ui(ButtonBadge_BMsg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	fast := f64(ui.tree.theme.motion.fast)
	ui_tick(&ui, 1000)
	b := bell(&ui, nil)
	b = bell(&ui, Button_Badge{dot = true})
	_, _, _, ok := badge_drawn(&ui, b)
	testing.expect(t, !ok, "it starts from nothing")
	ui_tick(&ui, 1000 + fast / 2)
	frame(&ui.tree, {200, 36})
	r: Rect
	r, _, _, ok = badge_drawn(&ui, b)
	testing.expectf(t, ok && r.w > 0.5 && r.w < BUTTON_BADGE_DOT, "half way it is growing: %v", r.w)
	ui_tick(&ui, 1000 + fast + 20)
	frame(&ui.tree, {200, 36})
	r, _, _, _ = badge_drawn(&ui, b)
	testing.expect_value(t, r.w, BUTTON_BADGE_DOT)

	ui_tick(&ui, 2000)
	b = bell(&ui, Button_Badge{}) // the notifications were seen
	ui_tick(&ui, 2000 + fast / 2)
	frame(&ui.tree, {200, 36})
	r, _, _, ok = badge_drawn(&ui, b)
	testing.expectf(t, ok && r.w < BUTTON_BADGE_DOT, "it shrinks away: %v", r.w)
	ui_tick(&ui, 2000 + fast + 20)
	frame(&ui.tree, {200, 36})
	_, _, _, ok = badge_drawn(&ui, b)
	testing.expect(t, !ok, "then it is gone")

	ui.tree.theme.motion.reduce = true
	b = bell(&ui, Button_Badge{text = "2"})
	_, _, _, ok = badge_drawn(&ui, b)
	testing.expect(t, ok, "reduce motion: at once")
	b = bell(&ui, Button_Badge{})
	_, _, _, ok = badge_drawn(&ui, b)
	testing.expect(t, !ok, "and gone at once")
}

// A badge in a colour of its own gets the text colour that reads on it; a
// disabled button dims its badge with the rest of it.
@(test)
a_button_badge_reads_on_its_colour_and_dims :: proc(t: ^testing.T) {
	ui: Ui(ButtonBadge_BMsg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	b := bell(&ui, Button_Badge{text = "!", color = {1, 0.85, 0.2, 1}}) // a light amber
	_, _, tx, _ := badge_drawn(&ui, b)
	testing.expect_value(t, tx.color, Color{0, 0, 0, 1})

	dark: Ui(ButtonBadge_BMsg)
	ui_init(&dark)
	defer ui_destroy(&dark)
	b = bell(&dark, Button_Badge{text = "!", color = {0.6, 0.05, 0.1, 1}}) // a deep red
	_, _, tx, _ = badge_drawn(&dark, b)
	testing.expect_value(t, tx.color, Color{1, 1, 1, 1})

	off: Ui(ButtonBadge_BMsg)
	ui_init(&off)
	defer ui_destroy(&off)
	b = bell(&off, Button_Badge{dot = true}, disabled = true)
	_, c, _, ok := badge_drawn(&off, b)
	testing.expect(t, ok)
	testing.expect_value(t, c.a, off.tree.theme.color.primary.a * off.tree.theme.state.disabled_alpha)
}

} // when ODIN_TEST