package baldr

@(require) import "core:strings"
@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too; behind this `when` an app does not pay for them.
// ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh check look
// inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

C2_Kind :: enum { None, Pick, Flip, Close }
C2_Msg :: struct {
	kind: C2_Kind,
	i:    int,
	on:   bool,
}

@(private = "file")
on_pick :: proc(e: Ev(int)) -> C2_Msg { return {kind = .Pick, i = e.value} }
@(private = "file")
on_flip :: proc(e: Ev(bool)) -> C2_Msg { return {kind = .Flip, i = int(e.tag), on = e.value} }

@(private = "file")
mid :: proc(ui: ^Ui(C2_Msg), n: Node) -> [2]f32 {
	r := node_get(&ui.tree, n).abs
	return {r.x + r.w / 2, r.y + r.h / 2}
}

// A radio group is one Tab stop of Radios: a click picks (and focuses the
// group), the arrows move the pick and wrap, Home / End jump; the picked
// item carries Checked; the group paints the ring around it.
@(test)
radio_group_picks_by_click_and_arrows :: proc(t: ^testing.T) {
	ui: Ui(C2_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	opts := []string{"Apple", "Cherry", "Plum"}
	view :: proc(ui: ^Ui(C2_Msg), opts: []string, sel: int) -> Node {
		set_viewport(&ui.tree, {400, 300})
		begin_view(ui)
		column(ui, padding = .lg)
		g := radio(ui, sel, opts, on_pick, label = "Fruit")
		end(ui)
		end_view(ui)
		frame(&ui.tree, {400, 300})
		return g
	}
	g := view(&ui, opts, 1)
	dump := access_dump(&ui.tree)
	testing.expect(t, strings.contains(dump, "Group \"Fruit\""), dump)
	testing.expect(t, strings.contains(dump, "Radio \"Cherry\"") && strings.contains(dump, "Checked"), dump)
	testing.expect(t, !strings.contains(dump, "Text \"Apple\""), "labels are not separate a11y nodes")
	items := ui.tree.choices[g].items
	testing.expect_value(t, len(items), 3)
	testing.expect(t, .Focusable in node_get(&ui.tree, g).flags && .Focusable not_in node_get(&ui.tree, items[0]).flags, "one Tab stop")
	p := mid(&ui, items[2])
	pointer_button(&ui, .Left, true, p)
	pointer_button(&ui, .Left, false, p)
	testing.expect_value(t, ui.msgs[len(ui.msgs) - 1], C2_Msg{kind = .Pick, i = 2})
	testing.expect_value(t, ui.tree.focus, g)
	clear(&ui.msgs)
	g = view(&ui, opts, 2)
	set_focus(&ui.tree, g, true)
	key_event(&ui, .Down, true, {})
	testing.expect_value(t, ui.msgs[len(ui.msgs) - 1], C2_Msg{kind = .Pick, i = 0}) // wraps
	g = view(&ui, opts, 0) // the app applies each pick
	key_event(&ui, .Up, true, {})
	testing.expect_value(t, ui.msgs[len(ui.msgs) - 1], C2_Msg{kind = .Pick, i = 2}) // wraps back
	g = view(&ui, opts, 2)
	key_event(&ui, .Up, true, {})
	testing.expect_value(t, ui.msgs[len(ui.msgs) - 1], C2_Msg{kind = .Pick, i = 1})
	g = view(&ui, opts, 1)
	key_event(&ui, .End, true, {})
	testing.expect_value(t, ui.msgs[len(ui.msgs) - 1], C2_Msg{kind = .Pick, i = 2})
	g = view(&ui, opts, 2)
	n_before := len(ui.msgs)
	key_event(&ui, .End, true, {})
	testing.expect_value(t, len(ui.msgs), n_before) // already there: nothing to send
	key_event(&ui, .Home, true, {})
	testing.expect_value(t, ui.msgs[len(ui.msgs) - 1], C2_Msg{kind = .Pick, i = 0})
	g = view(&ui, opts, 2)
	set_focus(&ui.tree, g, true)
	// the ring is painted around the picked item, not the whole group
	frame(&ui.tree, {400, 300})
	ring_on_item, ring_on_group := false, false
	ir, gr := node_get(&ui.tree, items[2]).abs, node_get(&ui.tree, g).abs
	for _, l in ui.tree.layers do for c in l.cmds {
		if r, ok := c.(Draw_Rect); ok && r.border_w == 2 && r.border.r == ui.theme.color.focus_ring.r && r.border.g == ui.theme.color.focus_ring.g {
			if abs(r.rect.x - (ir.x - 3)) < 0.5 && abs(r.rect.w - (ir.w + 6)) < 0.5 do ring_on_item = true
			if abs(r.rect.x - (gr.x - 3)) < 0.5 && abs(r.rect.h - (gr.h + 6)) < 0.5 do ring_on_group = true
		}
	}
	testing.expect(t, ring_on_item && !ring_on_group, "the ring sits on the pick")
}

// A segmented control is the same choice with a gliding pill: the pill's
// position eases from the old segment to the new one.
@(test)
segmented_control_pill_glides_to_the_pick :: proc(t: ^testing.T) {
	ui: Ui(C2_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	labels := []string{"Compact", "Comfortable", "Spacious"}
	view :: proc(ui: ^Ui(C2_Msg), labels: []string, sel: int) -> Node {
		set_viewport(&ui.tree, {400, 300})
		begin_view(ui)
		column(ui, padding = .lg, align = .Start)
		g := segmented(ui, sel, labels, on_pick, label = "Density")
		end(ui)
		end_view(ui)
		frame(&ui.tree, {400, 300})
		return g
	}
	g := view(&ui, labels, 0)
	ui_tick(&ui, 1000)
	frame(&ui.tree, {400, 300})
	items := ui.tree.choices[g].items
	pill_x :: proc(ui: ^Ui(C2_Msg), items: []Node) -> f32 {
		bg := ui.theme.color.surface_high
		h := node_get(&ui.tree, items[0]).abs.h
		for _, l in ui.tree.layers do for c in l.cmds {
			if r, ok := c.(Draw_Rect); ok && r.color.r == bg.r && r.color.g == bg.g && r.color.b == bg.b && abs(r.rect.h - h) < 0.5 && r.border_w == 0 do return r.rect.x
		}
		return -1
	}
	x0 := node_get(&ui.tree, items[0]).abs.x
	testing.expectf(t, abs(pill_x(&ui, items[:]) - x0) < 0.5, "pill under the first segment, got %g want %g", pill_x(&ui, items[:]), x0)
	p := mid(&ui, items[2])
	pointer_button(&ui, .Left, true, p)
	pointer_button(&ui, .Left, false, p)
	testing.expect_value(t, ui.msgs[len(ui.msgs) - 1], C2_Msg{kind = .Pick, i = 2})
	view(&ui, labels, 2)
	ui_tick(&ui, 1050)
	frame(&ui.tree, {400, 300})
	x2 := node_get(&ui.tree, items[2]).abs.x
	mid_x := pill_x(&ui, items[:])
	testing.expectf(t, mid_x > x0 && mid_x < x2, "mid-glide the pill is between: %g in (%g, %g)", mid_x, x0, x2)
	for i in 1 ..= 40 do ui_tick(&ui, 1050 + f64(i) * 16)
	frame(&ui.tree, {400, 300})
	testing.expectf(t, abs(pill_x(&ui, items[:]) - x2) < 0.5, "settled under the third: %g want %g", pill_x(&ui, items[:]), x2)
}

// progress reports its value and eases the fill to it; indeterminate is
// Busy and keeps a band moving (still under reduce-motion). spinner is a
// polite Busy status painting eight dots. badge is plain text on a tone.
@(test)
progress_spinner_and_badge :: proc(t: ^testing.T) {
	ui: Ui(C2_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	view :: proc(ui: ^Ui(C2_Msg), v: f32) -> (bar, ind, sp, bd: Node) {
		set_viewport(&ui.tree, {400, 300})
		begin_view(ui)
		column(ui, padding = .lg, gap = .md)
		bar = progress(ui, v, label = "Upload", width = 200)
		ind = progress(ui, 0, label = "Working", width = 200, indeterminate = true)
		sp = spinner(ui, label = "Loading files")
		bd = badge(ui, "3 new", tone = .Success)
		end(ui)
		end_view(ui)
		frame(&ui.tree, {400, 300})
		return
	}
	bar, ind, sp, bd := view(&ui, 0.25)
	ui_tick(&ui, 1000)
	frame(&ui.tree, {400, 300})
	b := node_get(&ui.tree, bar)
	testing.expect(t, b.access.role == .Progress && b.access.has_value && b.access.value == 0.25 && b.access.value_max == 1)
	testing.expect(t, .Busy in node_get(&ui.tree, ind).access.states && !node_get(&ui.tree, ind).access.has_value, "indeterminate is Busy without a value")
	fill_w :: proc(ui: ^Ui(C2_Msg), bar: Node) -> f32 {
		br := node_get(&ui.tree, bar).abs
		c := ui.theme.color.primary
		for _, l in ui.tree.layers do for cmd in l.cmds {
			if r, ok := cmd.(Draw_Rect); ok && r.color.r == c.r && r.color.g == c.g && r.color.b == c.b && r.rect.x == br.x && r.rect.y == br.y do return r.rect.w
		}
		return 0
	}
	for i in 1 ..= 40 do ui_tick(&ui, 1000 + f64(i) * 16)
	frame(&ui.tree, {400, 300})
	testing.expectf(t, abs(fill_w(&ui, bar) - 50) < 0.5, "a quarter of 200 px: %g", fill_w(&ui, bar))
	view(&ui, 0.75) // built at 1640 ms on the tree clock
	ui_tick(&ui, 1700)
	frame(&ui.tree, {400, 300})
	w_mid := fill_w(&ui, bar)
	testing.expectf(t, w_mid > 50 && w_mid < 150, "the fill eases: %g", w_mid)
	testing.expect(t, ui.tree.anim_active, "the indeterminate band keeps the clock running")
	s := node_get(&ui.tree, sp)
	testing.expect(t, s.access.role == .Status && .Busy in s.access.states && s.access.live == .Polite && s.access.name == "Loading files")
	dots := 0
	sr := s.abs
	for _, l in ui.tree.layers do for cmd in l.cmds {
		if r, ok := cmd.(Draw_Rect); ok && r.rect.x >= sr.x && r.rect.x + r.rect.w <= sr.x + sr.w + 0.01 && r.rect.y >= sr.y && r.rect.w < 6 do dots += 1
	}
	testing.expect_value(t, dots, 8)
	bn := node_get(&ui.tree, bd)
	testing.expect(t, bn.access.role == .Text && bn.access.name == "3 new")
	bg, fg := tone_colors(&ui.theme, .Success)
	testing.expect(t, contrast_ratio(fg, bg) >= 4.5, "a badge reads on its tone")
	// reduce-motion: the band holds still
	th := ui.theme
	th.motion.reduce = true
	set_theme(&ui.tree, th)
	view(&ui, 0.75)
	ui_tick(&ui, 3000)
	frame(&ui.tree, {400, 300})
	testing.expect(t, !anim_running(&ui.tree, ind, .Scroll), "no sweep under reduce-motion")
}

// A chip flips with a click or Enter (Pressed state, check mark), its ×
// removes it, and so do Backspace / Delete while it is focused.
@(test)
chip_flips_and_removes :: proc(t: ^testing.T) {
	ui: Ui(C2_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	view :: proc(ui: ^Ui(C2_Msg), sel: bool) -> (a, b: Node) {
		set_viewport(&ui.tree, {400, 300})
		begin_view(ui)
		row(ui, padding = .lg, gap = .sm)
		a = chip(ui, "Wayland", selected = sel, on_change = on_flip, tag = 1)
		b = chip(ui, "temp", on_close = C2_Msg{kind = .Close, i = 2})
		end(ui)
		end_view(ui)
		frame(&ui.tree, {400, 300})
		return
	}
	a, b := view(&ui, false)
	dump := access_dump(&ui.tree)
	testing.expect(t, strings.contains(dump, "Button \"Wayland\"") && strings.contains(dump, "Button \"Remove temp\""), dump)
	p := mid(&ui, a)
	pointer_button(&ui, .Left, true, p)
	pointer_button(&ui, .Left, false, p)
	testing.expect_value(t, ui.msgs[len(ui.msgs) - 1], C2_Msg{kind = .Flip, i = 1, on = true})
	a, b = view(&ui, true)
	testing.expect(t, .Pressed in node_get(&ui.tree, a).access.states)
	set_focus(&ui.tree, a, true)
	key_event(&ui, .Enter, true, {})
	testing.expect_value(t, ui.msgs[len(ui.msgs) - 1], C2_Msg{kind = .Flip, i = 1, on = false})
	// the ×
	x := node_get(&ui.tree, b).last
	px := mid(&ui, x)
	pointer_button(&ui, .Left, true, px)
	pointer_button(&ui, .Left, false, px)
	testing.expect_value(t, ui.msgs[len(ui.msgs) - 1], C2_Msg{kind = .Close, i = 2})
	clear(&ui.msgs)
	set_focus(&ui.tree, b, true)
	testing.expect(t, key_event(&ui, .Delete, true, {}))
	testing.expect_value(t, ui.msgs[len(ui.msgs) - 1], C2_Msg{kind = .Close, i = 2})
}

// An expander's header is a Button with Expanded / Collapsed; the content
// scope opens only while expanded and one end closes it.
@(test)
expander_opens_its_content_scope :: proc(t: ^testing.T) {
	ui: Ui(C2_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	view :: proc(ui: ^Ui(C2_Msg), open: bool) -> (hdr, after: Node) {
		set_viewport(&ui.tree, {400, 300})
		begin_view(ui)
		column(ui, padding = .lg)
		if expander(ui, "Advanced", open, on_change = on_flip, tag = 7) {
			text(ui, "hidden until opened")
			end(ui)
		}
		after = text(ui, "after")
		end(ui)
		end_view(ui)
		frame(&ui.tree, {400, 300})
		hdr = node_first(&ui.tree, node_first(&ui.tree, node_first(&ui.tree, ui.root)))
		return
	}
	hdr, after := view(&ui, false)
	hd := node_get(&ui.tree, hdr)
	testing.expect(t, hd.access.role == .Button && hd.access.name == "Advanced" && .Collapsed in hd.access.states, "a collapsed header")
	testing.expect(t, !strings.contains(access_dump(&ui.tree), "hidden until"), "no content while collapsed")
	y_closed := node_get(&ui.tree, after).abs.y
	p := mid(&ui, hdr)
	pointer_button(&ui, .Left, true, p)
	pointer_button(&ui, .Left, false, p)
	testing.expect_value(t, ui.msgs[len(ui.msgs) - 1], C2_Msg{kind = .Flip, i = 7, on = true})
	hdr, after = view(&ui, true)
	testing.expect(t, .Expanded in node_get(&ui.tree, hdr).access.states)
	testing.expect(t, strings.contains(access_dump(&ui.tree), "hidden until"), "content is built")
	testing.expect(t, node_get(&ui.tree, after).abs.y > y_closed, "…and pushes what follows down")
	testing.expect_value(t, len(ui.diags), 0)
}

} // when ODIN_TEST