package baldr

@(require) import "core:math"
@(require) import "base:runtime"
@(require) import "core:testing"
@(require) import "baldr:gpu"
@(require) import "baldr:platform"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: they sit behind this `when` so an app does not pay
// for them. ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh
// check look inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// Popups from layer surfaces: a bar's menus and popovers on surfaces of
// their own.


@(private = "file")
Popup_PMsg :: enum { None, Close }

@(private = "file")
tall_cmds :: proc(cmds: []Draw_Cmd) -> (n: int) {
	for c in cmds {
		#partial switch v in c {
		case Draw_Rect:     if v.rect.h > 100 do n += 1
		case Draw_Backdrop: if v.rect.h > 100 do n += 1
		case Draw_Shadow:   if v.rect.h > 100 do n += 1
		}
	}
	return
}

@(test)
popups_leave_the_bar_and_draw_on_their_own :: proc(t: ^testing.T) {
	ui: Ui(Popup_PMsg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	ui.tree.theme.motion.reduce = true
	ui.tree.popups_on = true
	build :: proc(ui: ^Ui(Popup_PMsg)) -> (tall: Node) {
		begin_view(ui)
		row(ui, flex = 1, align = .Center)
		apps := button(ui, "Apps", Popup_PMsg.None)
		end(ui)
		if popover(ui, apps, true, Popup_PMsg.Close) {
			tall = box(ui, width = 200, height = 300)
			end(ui)
		}
		end_view(ui)
		return
	}
	tall := build(&ui)
	frame(&ui.tree, {800, 36})
	pop := node_first(&ui.tree, ui.tree.overlay)
	pd := node_get(&ui.tree, pop)
	testing.expectf(t, pd.rect.h > 300, "the popover keeps its height past the 36 px bar: %v", pd.rect.h)
	testing.expect_value(t, tall_cmds(draw_list(&ui.tree)), 0) // the bar doesn't draw it
	testing.expect(t, tall_cmds(popup_draw_list(&ui.tree, pop)) > 0, "its own surface does")

	ui.tree.popups[pop] = {origin = {10, 42}, placed = true} // the compositor put it below the bar
	build(&ui)
	frame(&ui.tree, {800, 36})
	pd = node_get(&ui.tree, pop)
	testing.expect_value(t, [2]f32{pd.abs.x, pd.abs.y}, [2]f32{10, 42})
	td := node_get(&ui.tree, tall)
	inside := [2]f32{td.abs.x + 5, td.abs.y + 5}
	testing.expect(t, hit_test(&ui.tree, inside) != tall, "the bar's own hits pass it by")
	ui.tree.pointer_scope = pop // the pointer is over the popup's surface
	testing.expect_value(t, hit_test(&ui.tree, inside), tall)
	ui.tree.pointer_scope = NODE_NONE

	cmds := make([dynamic]gpu.Cmd, context.temp_allocator)
	render_popup(&ui.tree, pop, {10 - 20, 42 - 20}, 1, nil, &cmds)
	at_margin := false
	for c in cmds {
		#partial switch v in c {
		case gpu.Quad:     if v.rect.x == 20 && v.rect.y == 20 do at_margin = true
		case gpu.Backdrop: if v.rect.x == 20 && v.rect.y == 20 do at_margin = true
		}
	}
	testing.expect(t, at_margin, "its surface draws the card from its corner, past the margin")
}

@(test)
tooltips_stay_off_a_control_whose_popover_is_open :: proc(t: ^testing.T) {
	ui: Ui(Popup_PMsg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	ui.tree.theme.motion.reduce = true
	build :: proc(ui: ^Ui(Popup_PMsg), open: bool) -> (anchor: Node) {
		set_viewport(&ui.tree, {400, 200})
		begin_view(ui)
		column(ui, padding = .lg)
		anchor = button(ui, "Control", Popup_PMsg.None)
		tooltip(ui, anchor, "Wi-Fi, sound and display")
		end(ui)
		if popover(ui, anchor, open, Popup_PMsg.Close) {
			text(ui, "Inside")
			end(ui)
		}
		end_view(ui)
		frame(&ui.tree, {400, 200})
		return
	}
	anchor := build(&ui, false)
	ad := node_get(&ui.tree, anchor)
	pointer_move(&ui, {ad.abs.x + 4, ad.abs.y + 4})
	ui_after_events(&ui, 100)
	ui_after_events(&ui, 100 + TOOLTIP_DELAY_MS + 1)
	testing.expect_value(t, ui.tip_anchor, anchor) // resting on it: its tooltip
	build(&ui, true)
	ui_after_events(&ui, 2000)
	testing.expect_value(t, ui.tip_anchor, NODE_NONE) // its popover opened: the tooltip goes
	ui_after_events(&ui, 4000)
	testing.expect_value(t, ui.tip_anchor, NODE_NONE) // and stays away while the popover is open
}

@(private = "file")
Popup_Log :: struct {
	created:   [dynamic]platform.Popup_Desc,
	moved:     [dynamic]platform.Popup_Desc,
	destroyed: [dynamic]platform.Surface,
	next:      platform.Surface,
	frames:    int, // frames asked for
}

@(private = "file")
Look :: struct {
	open, extra: bool,
}

@(private = "file")
popup_test_build :: proc(c: ^Surface_Ctx(Popup_PMsg), look: Look) -> (apps: Node) {
	ui := &c.ui
	set_viewport(&ui.tree, {800, 36})
	begin_view(ui)
	row(ui, flex = 1, align = .Center)
	apps = button(ui, "Apps", Popup_PMsg.None)
	end(ui)
	if menu(ui, apps, look.open, Popup_PMsg.Close) {
		menu_item(ui, "One", Popup_PMsg.None)
		if look.extra do menu_item(ui, "Two", Popup_PMsg.None)
		if submenu(ui, "More") {
			menu_item(ui, "Deeper", Popup_PMsg.None)
			end(ui)
		}
		end(ui)
	}
	end_view(ui)
	return
}

// A drag's ghost moves, it does not re-open. A popup is found by its node,
// so a keyed overlay with a fixed rule, moved every build as the ghost
// follows the pointer, is created once and repositioned after that; a new
// popup is a surface and a swapchain target each.
@(test)
a_moving_ghost_is_repositioned_not_reopened :: proc(t: ^testing.T) {
	log := Popup_Log{next = 10}
	defer {
		delete(log.created)
		delete(log.moved)
		delete(log.destroyed)
	}
	b := platform.Backend{data = &log, caps = {.Popups}}
	b.popup_create = proc(b: ^platform.Backend, d: platform.Popup_Desc) -> (platform.Surface, bool) {
		lg := (^Popup_Log)(b.data)
		append(&lg.created, d)
		lg.next += 1
		return lg.next, true
	}
	b.popup_reposition = proc(b: ^platform.Backend, s: platform.Surface, d: platform.Popup_Desc) -> bool {
		append(&(^Popup_Log)(b.data).moved, d)
		return true
	}
	b.surface_destroy = proc(b: ^platform.Backend, s: platform.Surface) {
		append(&(^Popup_Log)(b.data).destroyed, s)
	}
	c: Surface_Ctx(Popup_PMsg)
	c.desc.kind = .Layer
	c.surf = 1
	ui_init(&c.ui)
	defer ui_destroy(&c.ui)
	defer delete(c.popups)
	defer popups_close_all(&b, nil, &c)
	c.ui.tree.theme.motion.reduce = true
	set_viewport(&c.ui.tree, {800, 600})

	GHOST :: u64(0xD5A6_0000_0000_0001)
	here := runtime.Source_Code_Location{}
	nodes := make([dynamic]Node, context.temp_allocator)
	for step in 0 ..< 20 { // the pointer walking along a dock
		begin_view(&c.ui)
		column(&c.ui)
		text(&c.ui, "dock")
		end(&c.ui)
		n, created := overlay_begin(&c.ui, GHOST, here)
		if created do transition(&c.ui, n, .Fade_Scale, .Fade, 120)
		// Named with its type: an inline literal with every layer inferred
		// costs the compiler minutes (see CONTRIBUTING.md).
		at := [2]f32{f32(40 + step * 12), 300}
		rule := Overlay_Rule{fixed = true, at = at}
		c.ui.tree.overlay_rules[n] = rule
		text(&c.ui, "ghost")
		end(&c.ui)
		end_view(&c.ui)
		frame(&c.ui.tree, {800, 600})
		popups_sync(&b, nil, &c)
		append(&nodes, n)
	}

	// The ghost is one node for the whole drag…
	same := true
	for n in nodes do if n != nodes[0] do same = false
	testing.expect(t, same, "the ghost keeps one node while it moves")

	// …and therefore one popup, moved rather than made again.
	testing.expect_value(t, len(log.created), 1)
	testing.expect(t, len(log.moved) >= 10, "it was repositioned as it went")
	testing.expect_value(t, len(log.destroyed), 0)
}

// A drag's ghost outlives the popups it flies over. A fixed overlay opening
// for the first time takes as its parent whichever open popup contains it
// (`popup_desc_of`), and closing propagates to children, so a tooltip dying
// could take the ghost with it and the next build would open a new one.
// This pins that the ghost is not adopted.
@(test)
a_drag_ghost_is_not_adopted_by_a_popup_it_crosses :: proc(t: ^testing.T) {
	log := Popup_Log{next = 10}
	defer {
		delete(log.created); delete(log.moved); delete(log.destroyed)
	}
	b := platform.Backend{data = &log, caps = {.Popups}}
	b.popup_create = proc(b: ^platform.Backend, d: platform.Popup_Desc) -> (platform.Surface, bool) {
		lg := (^Popup_Log)(b.data)
		append(&lg.created, d); lg.next += 1
		return lg.next, true
	}
	b.popup_reposition = proc(b: ^platform.Backend, s: platform.Surface, d: platform.Popup_Desc) -> bool {
		append(&(^Popup_Log)(b.data).moved, d)
		return true
	}
	b.surface_destroy = proc(b: ^platform.Backend, s: platform.Surface) {
		append(&(^Popup_Log)(b.data).destroyed, s)
	}
	c: Surface_Ctx(Popup_PMsg)
	c.desc.kind = .Layer
	c.surf = 1
	ui_init(&c.ui)
	defer ui_destroy(&c.ui)
	defer delete(c.popups)
	defer popups_close_all(&b, nil, &c)
	c.ui.tree.theme.motion.reduce = true
	set_viewport(&c.ui.tree, {800, 600})

	GHOST2 :: u64(0xD5A6_0000_0000_0001)
	TIP :: u64(0x7117_0000_0000_0001)
	here := runtime.Source_Code_Location{}

	// Two builds with the tooltip there, so both are open and configured,
	// then the tooltip goes as the pointer moves off that icon.
	build_b :: proc(c: ^Surface_Ctx(Popup_PMsg), b: ^platform.Backend, with_tip, with_ghost: bool, here: runtime.Source_Code_Location) {
		begin_view(&c.ui)
		column(&c.ui)
		text(&c.ui, "dock")
		end(&c.ui)
		if with_tip {
			tn, _ := overlay_begin(&c.ui, TIP, here)
			tip_at := [2]f32{100, 290}
			tip_rule := Overlay_Rule{fixed = true, at = tip_at}
			c.ui.tree.overlay_rules[tn] = tip_rule
			text(&c.ui, "a tooltip wide enough to contain the ghost")
			end(&c.ui)
		}
		if with_ghost {
			gn, _ := overlay_begin(&c.ui, GHOST2, here)
			at := [2]f32{120, 300}
			rule := Overlay_Rule{fixed = true, at = at}
			c.ui.tree.overlay_rules[gn] = rule
			text(&c.ui, "ghost")
			end(&c.ui)
		}
		end_view(&c.ui)
		frame(&c.ui.tree, {800, 600})
		for p in c.popups do p.configured = true // as their configures would
		popups_sync(b, nil, c)
	}

	// The order is a real drag's: the tooltip is already up and configured
	// when the drag starts, so the ghost opens with a popup already under it.
	build_b(&c, &b, true, false, here)  // tooltip alone
	build_b(&c, &b, true, false, here)  // …and configured
	build_b(&c, &b, true, true, here)   // now the drag starts: the ghost appears
	build_b(&c, &b, true, true, here)
	made := len(log.created)
	testing.expect(t, made >= 2, "the tooltip and the ghost each opened")

	// The tooltip goes. The ghost must stay: it is not the tooltip's child.
	build_b(&c, &b, false, true, here)
	ghost_alive := false
	for p in c.popups do if node_get(&c.ui.tree, p.node).key == GHOST2 do ghost_alive = true
	testing.expect(t, ghost_alive, "the ghost outlives what it was flying over")
	testing.expect_value(t, len(log.created), made) // nothing re-opened
}

@(test)
popups_open_move_and_close_children_first :: proc(t: ^testing.T) {
	log := Popup_Log{next = 10}
	defer {
		delete(log.created)
		delete(log.moved)
		delete(log.destroyed)
	}
	b := platform.Backend{data = &log, caps = {.Popups}}
	b.popup_create = proc(b: ^platform.Backend, d: platform.Popup_Desc) -> (platform.Surface, bool) {
		lg := (^Popup_Log)(b.data)
		append(&lg.created, d)
		lg.next += 1
		return lg.next, true
	}
	b.popup_reposition = proc(b: ^platform.Backend, s: platform.Surface, d: platform.Popup_Desc) -> bool {
		append(&(^Popup_Log)(b.data).moved, d)
		return true
	}
	b.surface_destroy = proc(b: ^platform.Backend, s: platform.Surface) {
		append(&(^Popup_Log)(b.data).destroyed, s)
	}
	c: Surface_Ctx(Popup_PMsg)
	c.desc.kind = .Layer
	c.surf = 1
	ui_init(&c.ui)
	defer ui_destroy(&c.ui)
	defer delete(c.popups)
	defer popups_close_all(&b, nil, &c)
	c.ui.tree.theme.motion.reduce = true

	apps := popup_test_build(&c, {open = true})
	popups_sync(&b, nil, &c)
	testing.expect_value(t, len(log.created), 1)
	if len(log.created) != 1 do return
	menu_desc := log.created[0]
	ad := node_get(&c.ui.tree, apps)
	testing.expect_value(t, menu_desc.parent, platform.Surface(1))
	testing.expect_value(t, menu_desc.anchor, [4]f32{ad.abs.x, ad.abs.y, ad.abs.w, ad.abs.h})
	testing.expect(t, menu_desc.placement == .Below && menu_desc.grab && menu_desc.margin > 2 && menu_desc.size.y > 0, "a menu below its button, grabbing, with room for its shadow")

	for row in c.ui.submenus do submenu_open(&c.ui, row, false)
	popup_test_build(&c, {open = true})
	popups_sync(&b, nil, &c)
	testing.expect_value(t, len(log.created), 1) // the submenu waits until the menu is placed
	popup_configured(&c, c.popups[0], {0, 42})
	popups_sync(&b, nil, &c)
	testing.expect_value(t, len(log.created), 2)
	if len(log.created) != 2 do return
	sub := log.created[1]
	row_node: Node
	for row in c.ui.submenus do row_node = row
	rd := node_get(&c.ui.tree, row_node)
	testing.expect_value(t, sub.parent, c.popups[0].surf)
	testing.expect_value(t, sub.anchor, [4]f32{rd.abs.x, rd.abs.y - 42, rd.abs.w, rd.abs.h}) // in the menu's own coordinates
	testing.expect(t, sub.placement == .Right && sub.grab, "beside its row, grabbing too")

	popup_test_build(&c, {open = true, extra = true}) // the menu grows
	popups_sync(&b, nil, &c)
	testing.expect(t, len(log.moved) >= 1 && len(log.created) == 2, "moved in place, not opened again")

	popup_test_build(&c, {open = false})
	popups_sync(&b, nil, &c)
	testing.expect_value(t, len(c.popups), 0)
	testing.expect_value(t, len(log.destroyed), 2)
	if len(log.destroyed) == 2 do testing.expect(t, log.destroyed[0] == 12 && log.destroyed[1] == 11, "the submenu goes before the menu it opened from")
	testing.expect_value(t, len(c.ui.tree.popups), 0)

	popup_test_build(&c, {open = true})
	popups_sync(&b, nil, &c)
	testing.expect_value(t, len(c.popups), 1)
	clear(&c.ui.msgs)
	if len(c.popups) == 1 do popup_dismissed(&c, c.popups[0])
	testing.expect(t, len(c.ui.msgs) == 1 && c.ui.msgs[0] == .Close, "the compositor's dismissal sends the menu's dismiss message")
}

// A glass popup starts from the backdrop of what it opened from (the bar's
// report), so its tint is made for a backdrop from its first paint. It
// waits, presenting empty with its fade-in held at the start, until the
// compositor has measured behind it, or POPUP_BACKDROP_WAIT_MS. Its own
// report ends the wait, even one equal to the bar's, and one that differs
// adapts it again; where the compositor reports nothing it never waits.
@(test)
glass_popups_start_from_their_bars_backdrop_and_wait_for_their_own :: proc(t: ^testing.T) {
	log := Popup_Log{next = 10}
	defer {
		delete(log.created)
		delete(log.moved)
		delete(log.destroyed)
	}
	b := platform.Backend{data = &log, caps = {.Popups}}
	b.popup_create = proc(b: ^platform.Backend, d: platform.Popup_Desc) -> (platform.Surface, bool) {
		lg := (^Popup_Log)(b.data)
		append(&lg.created, d)
		lg.next += 1
		return lg.next, true
	}
	b.surface_destroy = proc(b: ^platform.Backend, s: platform.Surface) {
		append(&(^Popup_Log)(b.data).destroyed, s)
	}
	c: Surface_Ctx(Popup_PMsg)
	c.desc.kind = .Layer
	c.surf = 1
	ui_init(&c.ui)
	defer ui_destroy(&c.ui)
	defer delete(c.popups)
	defer popups_close_all(&b, nil, &c)
	tr := &c.ui.tree
	tr.theme.motion.reduce = false
	bar := Backdrop_Range{0.05, 0.1, 0.2}
	tree_glass(tr, true, true, .Panel, true)
	tree_backdrop(tr, bar)

	begin_view(&c.ui)
	set_viewport(tr, {800, 36})
	row(&c.ui, flex = 1, align = .Center)
	control := button(&c.ui, "Control", Popup_PMsg.None)
	end(&c.ui)
	if popover(&c.ui, control, true, Popup_PMsg.Close) {
		text(&c.ui, "Control Centre")
		end(&c.ui)
	}
	end_view(&c.ui)
	popups_sync(&b, nil, &c)
	testing.expect_value(t, len(c.popups), 1)
	if len(c.popups) != 1 do return
	n := c.popups[0].node
	testing.expect_value(t, log.created[0].backdrop, platform.Backdrop.Blur) // fixture: a glass popover
	place := tr.popups[n]
	testing.expect(t, place.known && place.backdrop == bar && !place.measured, "it starts from the bar's backdrop")
	th, ok := popup_theme(tr, n)
	want := tr.theme_base
	glass_adapt(tr, &want, .Popover, true, bar)
	testing.expect(t, ok && th.material[th.glass].popover.tint == want.material[want.glass].popover.tint, "its tint is made for that backdrop")

	now := place.wait_until - POPUP_BACKDROP_WAIT_MS
	testing.expect(t, popup_waiting(tr, n, now), "its first paint waits for its own report")
	testing.expect(t, !popup_waiting(tr, n, place.wait_until), "POPUP_BACKDROP_WAIT_MS at most")
	anim_restart(tr, n, .Enter, 0.6, 0.6, 0) // its fade-in under way
	popup_hold(tr, n)
	testing.expect_value(t, anim_value(tr, n, .Enter), 0) // held at its start

	testing.expect(t, popup_backdrop(tr, n, bar), "its own report, the same as the bar's, lets it show")
	testing.expect(t, !popup_waiting(tr, n, now), "measured: it shows")
	own := Backdrop_Range{0.7, 0.8, 0.9}
	testing.expect(t, popup_backdrop(tr, n, own) && tr.popups[n].backdrop == own, "a different report adapts it again")

	pl := &tr.popups[n]
	pl.measured = false
	tr.glass.reported = false // a compositor that reports nothing
	testing.expect(t, !popup_waiting(tr, n, now), "it never waits where no report comes")
}

// A bar's popup keeps POPUP_BAR_GAP from the bar's outer edge, not from the
// button inside it, and every popup keeps POPUP_SCREEN_MARGIN from the
// screen's edges: its window geometry is the card with that room around
// it, which the compositor keeps on the screen. The positioner and the
// configure agree on where the card is, for a popup opened from another
// popup too and for a menu at a point.
@(test)
bar_popups_keep_clear_of_the_bar_and_the_screen_edges :: proc(t: ^testing.T) {
	log := Popup_Log{next = 10}
	defer {
		delete(log.created)
		delete(log.moved)
		delete(log.destroyed)
	}
	b := platform.Backend{data = &log, caps = {.Popups}}
	b.popup_create = proc(b: ^platform.Backend, d: platform.Popup_Desc) -> (platform.Surface, bool) {
		lg := (^Popup_Log)(b.data)
		append(&lg.created, d)
		lg.next += 1
		return lg.next, true
	}
	b.surface_destroy = proc(b: ^platform.Backend, s: platform.Surface) {
		append(&(^Popup_Log)(b.data).destroyed, s)
	}
	c: Surface_Ctx(Popup_PMsg)
	c.desc.kind = .Layer
	c.surf = 1
	c.ui.surface.edge = .Left // a dock on the screen's left edge, 56 px wide
	ui_init(&c.ui)
	defer ui_destroy(&c.ui)
	defer delete(c.popups)
	defer popups_close_all(&b, nil, &c)
	c.ui.tree.theme.motion.reduce = true

	begin_view(&c.ui)
	set_viewport(&c.ui.tree, {56, 600})
	column(&c.ui, flex = 1, padding = .sm)
	spacer(&c.ui, 200)
	apps := button(&c.ui, "Apps", Popup_PMsg.None, icon = .Layout_Grid, icon_only = true)
	end(&c.ui)
	if popover(&c.ui, apps, true, Popup_PMsg.Close) {
		box(&c.ui, width = 300, height = 200)
		end(&c.ui)
	}
	end_view(&c.ui)
	popups_sync(&b, nil, &c)
	testing.expect_value(t, len(log.created), 1)
	if len(log.created) != 1 do return
	desc := log.created[0]
	ad := node_get(&c.ui.tree, apps).abs
	testing.expect_value(t, desc.placement, platform.Popup_Placement.Right)
	testing.expect(t, ad.x > 0 && ad.x + ad.w < 56, "fixture: the button sits inside the dock")
	testing.expect_value(t, desc.anchor, [4]f32{ad.x, ad.y, 56 - ad.x, ad.h}) // out to the dock's outer edge
	testing.expect(t, desc.gap == POPUP_BAR_GAP && desc.clear == POPUP_SCREEN_MARGIN && desc.margin >= desc.clear, "8 px from the dock, 8 px kept clear, inside the margin")

	r := platform.popup_positioner_rects(desc, 0)
	card_left := f32(r.anchor[0] + r.anchor[2]) + desc.clear // the geometry starts at the anchor's right edge, the card `clear` into it
	testing.expect_value(t, card_left, 56 + POPUP_BAR_GAP)
	testing.expect_value(t, f32(r.anchor[1]) + desc.clear, math.floor(ad.y)) // lined up with the button
	testing.expect_value(t, r.size, [2]i32{i32(math.ceil(desc.size.x + 16)), i32(math.ceil(desc.size.y + 16))})
	// the compositor slid it up from the screen's bottom: its geometry at y 392 leaves the card 8 px clear
	pos, size := platform.popup_card_of({64 - 8, 392, r.size.x, r.size.y}, desc.clear, 0)
	testing.expect(t, pos == {64, 400} && size == [2]f32{f32(r.size.x) - 16, f32(r.size.y) - 16}, "the configure maps back to the card")

	sub := platform.Popup_Desc{anchor = {10, 20, 280, 30}, size = {200, 100}, placement = .Right, gap = -4, clear = 8, margin = 20}
	sr := platform.popup_positioner_rects(sub, 8) // opened from a popup that keeps 8 px clear itself
	testing.expect_value(t, f32(sr.anchor[0] + sr.anchor[2]) + 8, f32(8 + 10 + 280 - 4)) // in the parent's geometry: its card starts 8 px in
	spos, _ := platform.popup_card_of({sr.anchor[0] + sr.anchor[2], sr.anchor[1], sr.size.x, sr.size.y}, 8, 8)
	testing.expect_value(t, spos, [2]f32{10 + 280 - 4, 20}) // back in the parent's card

	at := platform.popup_positioner_rects({anchor = {100, 50, 1, 1}, size = {150, 80}, placement = .At, clear = 8, margin = 20}, 0)
	testing.expect_value(t, at.anchor, [4]i32{92, 42, 17, 17}) // the card's corner at the point, either way it flips

	testing.expect_value(t, popup_bar_anchor({500, 4, 90, 28}, .Top, {1280, 36}), [4]f32{500, 4, 90, 32}) // a top bar's: down to its bottom
	testing.expect_value(t, popup_bar_anchor({500, 4, 90, 28}, .Bottom, {1280, 36}), [4]f32{500, 0, 90, 32})
}

// A drawn popup whose card changes size (a page change easing a popover's
// height) moves with its frames. Between frames it only asks for one; the
// frame sends the new place and waits for the configure, one move at a time,
// then draws at the clock it was laid out at, so the card drawn is the size
// the compositor placed. With no configure the wait ends after
// POPUP_PLACE_WAIT_MS; once the card settles, frames draw at once.
@(test)
a_drawn_popup_moves_with_its_frames :: proc(t: ^testing.T) {
	log := Popup_Log{next = 10}
	defer {
		delete(log.created)
		delete(log.moved)
		delete(log.destroyed)
	}
	b := platform.Backend{data = &log, caps = {.Popups}}
	b.popup_create = proc(b: ^platform.Backend, d: platform.Popup_Desc) -> (platform.Surface, bool) {
		lg := (^Popup_Log)(b.data)
		append(&lg.created, d)
		lg.next += 1
		return lg.next, true
	}
	b.popup_reposition = proc(b: ^platform.Backend, s: platform.Surface, d: platform.Popup_Desc) -> bool {
		append(&(^Popup_Log)(b.data).moved, d)
		return true
	}
	b.surface_request_frame = proc(b: ^platform.Backend, s: platform.Surface) {
		(^Popup_Log)(b.data).frames += 1
	}
	b.surface_destroy = proc(b: ^platform.Backend, s: platform.Surface) {
		append(&(^Popup_Log)(b.data).destroyed, s)
	}
	c: Surface_Ctx(Popup_PMsg)
	c.desc.kind = .Layer
	c.surf = 1
	ui_init(&c.ui)
	defer ui_destroy(&c.ui)
	defer delete(c.popups)
	defer popups_close_all(&b, nil, &c)
	defer for p in c.popups do p.fc.target = 0 // fixture: no renderer to give the target back to
	tr := &c.ui.tree
	tr.theme.motion.reduce = false
	base := f64(tr.theme.motion.base)
	build :: proc(c: ^Surface_Ctx(Popup_PMsg), page: u64) {
		ui := &c.ui
		set_viewport(&ui.tree, {800, 36})
		begin_view(ui)
		row(ui, flex = 1, align = .Center)
		control := button(ui, "Control", Popup_PMsg.None)
		end(ui)
		if popover(ui, control, true, Popup_PMsg.Close) {
			pages(ui, page, int(page), key = 9)
			box(ui, width = 300, height = 400 if page == 0 else 100, key = 1)
			end(ui)
			end(ui)
		}
		end_view(ui)
	}
	ui_tick(&c.ui, 100)
	build(&c, 0)
	popups_sync(&b, nil, &c)
	testing.expect_value(t, len(c.popups), 1)
	if len(c.popups) != 1 do return
	p := c.popups[0]
	popup_configured(&c, p, {0, 44})
	p.fc.target = 1 // fixture: drawn, on a surface of its own
	tall := p.desc.size.y

	ui_tick(&c.ui, 1000)
	build(&c, 1) // a shorter page…
	popups_sync(&b, nil, &c) // …laid out: its card starts easing its height
	ui_tick(&c.ui, 1000 + base / 8)
	popups_sync(&b, nil, &c)
	testing.expect_value(t, len(log.moved), 0) // not moved between frames…
	testing.expect_value(t, log.frames, 1)     // …but a frame asked for

	now := 1000 + base / 4
	testing.expect(t, popup_resync(&b, &c, p, now), "the frame sends the new place and waits")
	testing.expect_value(t, len(log.moved), 1)
	if len(log.moved) != 1 do return
	sent := log.moved[0].size.y
	testing.expectf(t, sent < tall - 50 && sent > 150, "sent at the height the card has eased to: %v of %v", sent, tall)
	testing.expect(t, popup_resync(&b, &c, p, now + 4) && len(log.moved) == 1, "a frame while it waits waits too, sending nothing")
	popups_sync(&b, nil, &c)
	testing.expect_value(t, len(log.moved), 1) // one move at a time
	_, early := popup_take_held(p, now + 4)
	testing.expect(t, !early, "not drawn before its configure")

	popup_configured(&c, p, {0, 44})
	pin, due := popup_take_held(p, now + 6)
	testing.expect(t, due && pin == now, "drawn once the configure comes, at the clock it was laid out at")
	anim_tick(tr, pin)
	layout(tr, tr.viewport)
	testing.expect_value(t, node_get(tr, p.node).rect.h, sent) // the card it draws is the one placed
	testing.expect(t, !p.fc.frame_requested, "its next frame can be asked for")

	later := now + 16
	testing.expect(t, popup_resync(&b, &c, p, later), "the next frame moves it again")
	testing.expect_value(t, len(log.moved), 2)
	_, too_soon := popup_take_held(p, later + POPUP_PLACE_WAIT_MS - 1)
	_, waited := popup_take_held(p, later + POPUP_PLACE_WAIT_MS)
	testing.expect(t, !too_soon && waited, "with no configure, it is drawn after POPUP_PLACE_WAIT_MS")

	end_ms := 1000 + base * 2 // the ease is over
	ui_tick(&c.ui, end_ms)
	testing.expect(t, popup_resync(&b, &c, p, end_ms), "moved to the page's height")
	popup_configured(&c, p, {0, 44})
	popup_take_held(p, end_ms)
	testing.expect(t, !popup_resync(&b, &c, p, end_ms + 16), "settled: its frames draw at once")
	testing.expect_value(t, len(log.moved), 3)
}

// A popup's surface starts fitting its card and the margin its shadow draws
// in, and never shrinks while the popup is open: a shorter card keeps the
// surface it has, and a card that outgrows it gets a quarter of the card to
// spare, so a card easing between pages makes no new buffers.
@(test)
popup_surfaces_never_shrink_while_open :: proc(t: ^testing.T) {
	testing.expect_value(t, platform.popup_surface_size({392, 569}, 40, {}), [2]f32{472, 649})          // opening: it fits
	testing.expect_value(t, platform.popup_surface_size({392, 241}, 40, {472, 649}), [2]f32{472, 649}) // a shorter page: kept
	testing.expect_value(t, platform.popup_surface_size({392, 700}, 40, {472, 649}), [2]f32{472, 955}) // a taller one: 780, and a quarter of 700
	testing.expect_value(t, platform.popup_surface_size({392, 569}, 40, {472, 955}), [2]f32{472, 955}) // back to the first: kept
}

// A surface presents the part of what changed that lies on it. When
// everything that changed is off it (a popover easing on its own popup
// surface, beside a bar), the bar's frame has nothing to present.
@(test)
a_surface_presents_only_what_changed_on_it :: proc(t: ^testing.T) {
	out: [dynamic][4]f32
	defer delete(out)
	bar := [2]f32{800, 36}
	testing.expect(t, surface_damage({{10, 5, 20, 20}, {100, -300, 392, 290}}, false, bar, 2, &out), "a change on the bar presents")
	testing.expect_value(t, len(out), 1)
	if len(out) == 1 do testing.expect_value(t, out[0], [4]f32{20, 10, 40, 40}) // in device px at scale 2
	clear(&out)
	testing.expect(t, surface_damage({{790, 30, 40, 40}}, false, bar, 1, &out) && len(out) == 1 && out[0] == {790, 30, 10, 6}, "a change across its edge presents the part on it")
	clear(&out)
	testing.expect(t, !surface_damage({{100, -300, 392, 290}, {56, -620, 392, 600}}, false, bar, 1, &out), "only its popover changed: nothing to present")
	testing.expect_value(t, len(out), 0)
	testing.expect(t, !surface_damage({}, true, bar, 1, &out), "only a popup's content changed: nothing to present")
	testing.expect(t, surface_damage({}, false, bar, 1, &out) && len(out) == 0, "nothing changed at all: the whole surface presents")
}

// What changes inside a popover shown on a popup surface of its own (a card
// easing its height, its content) is not damage for the bar it opened from,
// only noted as a change elsewhere, so the bar's frame has nothing to
// present, and it doesn't count as the bar's layout, which would have a bar
// as long as its content measure itself again; a change on the bar does both.
@(test)
a_popovers_changes_are_not_its_bars_damage :: proc(t: ^testing.T) {
	log := Popup_Log{next = 10}
	defer {
		delete(log.created)
		delete(log.moved)
		delete(log.destroyed)
	}
	b := platform.Backend{data = &log, caps = {.Popups}}
	b.popup_create = proc(b: ^platform.Backend, d: platform.Popup_Desc) -> (platform.Surface, bool) {
		lg := (^Popup_Log)(b.data)
		append(&lg.created, d)
		lg.next += 1
		return lg.next, true
	}
	b.popup_reposition = proc(b: ^platform.Backend, s: platform.Surface, d: platform.Popup_Desc) -> bool { return true }
	b.surface_destroy = proc(b: ^platform.Backend, s: platform.Surface) {
		append(&(^Popup_Log)(b.data).destroyed, s)
	}
	c: Surface_Ctx(Popup_PMsg)
	c.desc.kind = .Layer
	c.surf = 1
	ui_init(&c.ui)
	defer ui_destroy(&c.ui)
	defer delete(c.popups)
	defer popups_close_all(&b, nil, &c)
	tr := &c.ui.tree
	tr.theme.motion.reduce = true
	build :: proc(c: ^Surface_Ctx(Popup_PMsg), tall, renamed: bool) {
		ui := &c.ui
		set_viewport(&ui.tree, {800, 36})
		begin_view(ui)
		row(ui, flex = 1, align = .Center)
		control := button(ui, "Controls" if renamed else "Control", Popup_PMsg.None)
		end(ui)
		if popover(ui, control, true, Popup_PMsg.Close) {
			box(ui, width = 300, height = 400 if tall else 100, bg = {1, 0, 0, 1}, key = 1)
			end(ui)
		}
		end_view(ui)
	}
	next :: proc(c: ^Surface_Ctx(Popup_PMsg), b: ^platform.Backend) -> (taken: []Rect, elsewhere: bool) {
		popups_sync(b, nil, c)
		frame(&c.ui.tree, {800, 36})
		elsewhere = c.ui.tree.damage_elsewhere
		c.ui.tree.damage_elsewhere = false
		return take_damage(&c.ui.tree), elsewhere
	}
	out: [dynamic][4]f32
	defer delete(out)
	build(&c, true, false)
	next(&c, &b)
	testing.expect_value(t, len(c.popups), 1)
	if len(c.popups) != 1 do return
	popup_configured(&c, c.popups[0], {0, 44})
	next(&c, &b)

	counted := tr.layouts
	build(&c, false, false) // only the popover's content changes
	taken, elsewhere := next(&c, &b)
	testing.expect_value(t, tr.layouts, counted) // no reason for a bar as long as its content to measure itself again
	testing.expect_value(t, len(taken), 0)
	testing.expect(t, elsewhere, "its change is noted, as another surface's")
	testing.expect(t, !surface_damage(taken, elsewhere, {800, 36}, 1, &out), "the bar has nothing to present")

	popup_configured(&c, c.popups[0], {0, 60}) // the compositor places the card elsewhere, as it does every frame of an eased height
	taken, elsewhere = next(&c, &b)
	testing.expectf(t, len(taken) == 0, "its new place is no damage for the bar: %v", taken)
	testing.expect(t, !surface_damage(taken, elsewhere, {800, 36}, 1, &out), "the bar still has nothing to present")

	build(&c, false, true) // the bar's button changes
	taken, elsewhere = next(&c, &b)
	testing.expect(t, tr.layouts > counted, "the bar's own change is")
	clear(&out)
	testing.expect(t, surface_damage(taken, elsewhere, {800, 36}, 1, &out) && len(out) > 0, "a change on the bar presents")
}

@(private = "file")
Popup_SMsg :: enum { None, Close, Dock }

// bar_menu_build: a bar whose right-click menu holds a submenu, "Add a panel".
@(private = "file")
bar_menu_build :: proc(c: ^Surface_Ctx(Popup_SMsg), open: bool) {
	ui := &c.ui
	set_viewport(&ui.tree, {800, 36})
	begin_view(ui)
	row(ui, flex = 1, align = .Center)
	text(ui, "A bar")
	end(ui)
	if context_menu(ui, open, Popup_SMsg.Close) {
		menu_item(ui, "Panel settings…", Popup_SMsg.None)
		if submenu(ui, "Add a panel") {
			menu_item(ui, "Top bar", Popup_SMsg.None)
			menu_item(ui, "Dock", Popup_SMsg.Dock)
			end(ui)
		}
		end(ui)
	}
	end_view(ui)
}

@(private = "file")
menu_item_named :: proc(t: ^Tree, n: Node, name: string) -> Node {
	d := node_get(t, n)
	if d == nil do return NODE_NONE
	if d.access.role == .Menu_Item && d.access.name == name do return n
	for ch := d.first; ch != NODE_NONE; ch = node_get(t, ch).next {
		if found := menu_item_named(t, ch, name); found != NODE_NONE do return found
	}
	return NODE_NONE
}

// A bar's right-click menu on a surface of its own and its
// submenu on another. A click on the submenu's item, arriving on the
// submenu's surface as the compositor reports it, is the item's, and the
// whole chain closes.
@(test)
a_context_menus_submenu_item_takes_a_click_on_its_own_surface :: proc(t: ^testing.T) {
	log := Popup_Log{next = 10}
	defer {
		delete(log.created)
		delete(log.moved)
		delete(log.destroyed)
	}
	b := platform.Backend{data = &log, caps = {.Popups}}
	b.popup_create = proc(b: ^platform.Backend, d: platform.Popup_Desc) -> (platform.Surface, bool) {
		lg := (^Popup_Log)(b.data)
		append(&lg.created, d)
		lg.next += 1
		return lg.next, true
	}
	b.popup_reposition = proc(b: ^platform.Backend, s: platform.Surface, d: platform.Popup_Desc) -> bool {
		append(&(^Popup_Log)(b.data).moved, d)
		return true
	}
	b.surface_destroy = proc(b: ^platform.Backend, s: platform.Surface) {
		append(&(^Popup_Log)(b.data).destroyed, s)
	}
	c: Surface_Ctx(Popup_SMsg)
	c.desc.kind = .Layer
	c.surf = 1
	ui_init(&c.ui)
	defer ui_destroy(&c.ui)
	defer delete(c.popups)
	defer popups_close_all(&b, nil, &c)
	c.ui.tree.theme.motion.reduce = true
	c.ui.context_pos = {300, 20} // the right-click on the bar

	bar_menu_build(&c, true)
	popups_sync(&b, nil, &c)
	testing.expect_value(t, len(c.popups), 1)
	if len(c.popups) != 1 do return
	popup_configured(&c, c.popups[0], {300, 36}) // the compositor put it below the bar
	for row in c.ui.submenus do submenu_open(&c.ui, row, false) // "Add a panel" clicked
	bar_menu_build(&c, true)
	popups_sync(&b, nil, &c)
	testing.expect_value(t, len(c.popups), 2)
	if len(c.popups) != 2 do return
	sub := c.popups[1] if c.popups[1].parent != nil else c.popups[0]
	testing.expect(t, sub.parent != nil, "fixture: the submenu is the menu's child popup")
	popup_configured(&c, sub, {190, 30}) // beside its row, in the menu's coordinates
	bar_menu_build(&c, true)
	popups_sync(&b, nil, &c)
	layout(&c.ui.tree, c.ui.tree.viewport)

	dock := menu_item_named(&c.ui.tree, sub.node, "Dock")
	testing.expect(t, dock != NODE_NONE, "fixture: Dock is in the submenu")
	if dock == NODE_NONE do return
	dd := node_get(&c.ui.tree, dock)
	sd := node_get(&c.ui.tree, sub.node)
	testing.expect_value(t, dd.abs.w, sd.abs.w - 2 * c.ui.tree.theme.space[.sm]) // the row fills its card
	centre := [2]f32{sd.abs.x + sd.abs.w - 12, dd.abs.y + dd.abs.h / 2} // right of its label: still the row
	on_surface := centre - sub.fc.origin // where the compositor reports the pointer, on the submenu's surface
	pointer_leave(&c.ui) // off the menu's surface…
	pointer_move(&c.ui, popup_pointer(&c, sub.surf, on_surface), moved = false) // …onto the submenu's
	pos := popup_pointer(&c, sub.surf, on_surface)
	testing.expect_value(t, pos, centre)
	pointer_move(&c.ui, pos)
	testing.expect_value(t, c.ui.pointer.hover, dock)
	clear(&c.ui.msgs)
	pointer_button(&c.ui, .Left, true, popup_pointer(&c, sub.surf, on_surface))
	pointer_button(&c.ui, .Left, false, popup_pointer(&c, sub.surf, on_surface))
	testing.expectf(t, len(c.ui.msgs) == 2 && c.ui.msgs[0] == .Dock && c.ui.msgs[1] == .Close, "Dock's message, then the menu's dismiss: %v", c.ui.msgs[:])
}

// The same, as it happens live: motion on, the submenu opened by a click on
// its row on the menu's surface, time passing, then the pointer onto the
// submenu's surface and a click on Dock.
@(test)
a_context_menus_submenu_opened_by_a_click_takes_its_items_click :: proc(t: ^testing.T) {
	log := Popup_Log{next = 10}
	defer {
		delete(log.created)
		delete(log.moved)
		delete(log.destroyed)
	}
	b := platform.Backend{data = &log, caps = {.Popups}}
	b.popup_create = proc(b: ^platform.Backend, d: platform.Popup_Desc) -> (platform.Surface, bool) {
		lg := (^Popup_Log)(b.data)
		append(&lg.created, d)
		lg.next += 1
		return lg.next, true
	}
	b.popup_reposition = proc(b: ^platform.Backend, s: platform.Surface, d: platform.Popup_Desc) -> bool {
		append(&(^Popup_Log)(b.data).moved, d)
		return true
	}
	b.surface_destroy = proc(b: ^platform.Backend, s: platform.Surface) {
		append(&(^Popup_Log)(b.data).destroyed, s)
	}
	c: Surface_Ctx(Popup_SMsg)
	c.desc.kind = .Layer
	c.surf = 1
	ui_init(&c.ui)
	defer ui_destroy(&c.ui)
	defer delete(c.popups)
	defer popups_close_all(&b, nil, &c)
	tr := &c.ui.tree
	now: f64 = 1000
	step :: proc(c: ^Surface_Ctx(Popup_SMsg), b: ^platform.Backend, now: ^f64, ms: f64) { // what a frame does: time, the view if asked, popups, layout
		now^ += ms
		ui_after_events(&c.ui, now^)
		if c.ui.needs_rebuild {
			c.ui.needs_rebuild = false
			bar_menu_build(c, true)
		}
		anim_tick(&c.ui.tree, now^)
		popups_sync(b, nil, c)
		layout(&c.ui.tree, c.ui.tree.viewport)
	}
	c.ui.context_pos = {300, 18}
	bar_menu_build(&c, true)
	step(&c, &b, &now, 16)
	if len(c.popups) != 1 do return
	menu := c.popups[0]
	popup_configured(&c, menu, {300, 18})
	step(&c, &b, &now, 16)
	step(&c, &b, &now, 400)

	row := menu_item_named(tr, menu.node, "Add a panel")
	testing.expect(t, row != NODE_NONE, "fixture: the row")
	if row == NODE_NONE do return
	rd := node_get(tr, row)
	at_row := [2]f32{rd.abs.x + rd.abs.w / 2, rd.abs.y + rd.abs.h / 2} - menu.fc.origin
	pointer_move(&c.ui, popup_pointer(&c, menu.surf, at_row), moved = false)
	pointer_button(&c.ui, .Left, true, popup_pointer(&c, menu.surf, at_row))
	pointer_button(&c.ui, .Left, false, popup_pointer(&c, menu.surf, at_row))
	step(&c, &b, &now, 16)
	testing.expectf(t, len(c.popups) == 2, "the submenu opened: %d popups", len(c.popups))
	if len(c.popups) != 2 do return
	sub := c.popups[1]
	popup_configured(&c, sub, {159, 34})
	for _ in 0 ..< 30 do step(&c, &b, &now, 16) // half a second: the rest delay, the fades

	pop_now := ui_submenu_of(&c.ui, row)
	testing.expectf(t, sub.node == pop_now, "the submenu's surface shows the submenu the menu has: popup node %v, the menu's %v", sub.node, pop_now)
	dock := menu_item_named(tr, sub.node, "Dock")
	testing.expect(t, dock != NODE_NONE, "fixture: Dock")
	if dock == NODE_NONE do return
	dd := node_get(tr, dock)
	card := node_get(tr, sub.node)
	testing.expect_value(t, dd.abs.w, card.abs.w - 2 * tr.theme.space[.sm]) // the row fills its card
	on_surface := [2]f32{card.abs.x + card.abs.w - 12, dd.abs.y + dd.abs.h / 2} - sub.fc.origin // right of its label: still the row
	pointer_leave(&c.ui)
	pointer_move(&c.ui, popup_pointer(&c, sub.surf, on_surface), moved = false)
	sd := node_get(tr, sub.node)
	flags: Node_Flags // the alias, not a spelled-out backing type, which can widen
	abs: Rect
	if sd != nil do flags, abs = sd.flags, sd.abs
	testing.expectf(t, c.ui.pointer.hover == dock, "the pointer on Dock hovers it: hover %v, scope %v, the popup's node flags %v, abs %v, pointer at %v",
		c.ui.pointer.hover, tr.pointer_scope, flags, abs, popup_pointer(&c, sub.surf, on_surface))
	clear(&c.ui.msgs)
	pointer_button(&c.ui, .Left, true, popup_pointer(&c, sub.surf, on_surface))
	pointer_button(&c.ui, .Left, false, popup_pointer(&c, sub.surf, on_surface))
	testing.expectf(t, len(c.ui.msgs) == 2 && c.ui.msgs[0] == .Dock && c.ui.msgs[1] == .Close, "Dock's message, then the menu's dismiss: %v", c.ui.msgs[:])
}

@(private = "file")
ui_submenu_of :: proc(ui: ^Ui(Popup_SMsg), row: Node) -> Node {
	pop, _ := ui.submenus[row]
	return pop
}

// A popup surface sits along its anchor by the popover's `align` too
// (a dock's launcher centred over its button). The desc
// carries it, a change of it moves the popup, and the positioner widens
// the anchor on the side the card lines up with — both sides for a
// centred one — so the card, not its shadow margin, lines up.
@(test)
a_popup_carries_its_popovers_alignment :: proc(t: ^testing.T) {
	log := Popup_Log{next = 10}
	defer {
		delete(log.created)
		delete(log.moved)
		delete(log.destroyed)
	}
	b := platform.Backend{data = &log, caps = {.Popups}}
	b.popup_create = proc(b: ^platform.Backend, d: platform.Popup_Desc) -> (platform.Surface, bool) {
		lg := (^Popup_Log)(b.data)
		append(&lg.created, d)
		lg.next += 1
		return lg.next, true
	}
	b.popup_reposition = proc(b: ^platform.Backend, s: platform.Surface, d: platform.Popup_Desc) -> bool {
		append(&(^Popup_Log)(b.data).moved, d)
		return true
	}
	b.surface_destroy = proc(b: ^platform.Backend, s: platform.Surface) {
		append(&(^Popup_Log)(b.data).destroyed, s)
	}
	c: Surface_Ctx(Popup_PMsg)
	c.desc.kind = .Layer
	c.surf = 1
	c.ui.surface.edge = .Bottom // a dock along the screen's bottom
	ui_init(&c.ui)
	defer ui_destroy(&c.ui)
	defer delete(c.popups)
	defer popups_close_all(&b, nil, &c)
	c.ui.tree.theme.motion.reduce = true

	build :: proc(c: ^Surface_Ctx(Popup_PMsg), align: Align) -> Node {
		begin_view(&c.ui)
		set_viewport(&c.ui.tree, {1280, 56})
		row(&c.ui, flex = 1, padding = .sm, justify = .Center)
		apps := button(&c.ui, "Apps", Popup_PMsg.None, icon = .Layout_Grid, icon_only = true)
		end(&c.ui)
		if popover(&c.ui, apps, true, Popup_PMsg.Close, align = align) {
			box(&c.ui, width = 620, height = 400)
			end(&c.ui)
		}
		end_view(&c.ui)
		return apps
	}
	build(&c, .Center)
	popups_sync(&b, nil, &c)
	testing.expect_value(t, len(log.created), 1)
	if len(log.created) != 1 do return
	desc := log.created[0]
	testing.expect_value(t, desc.placement, platform.Popup_Placement.Above)
	testing.expect_value(t, desc.align, platform.Popup_Align.Center)
	r := platform.popup_positioner_rects(desc, 0)
	ax := desc.anchor[0] + desc.anchor[2] / 2
	testing.expectf(t, abs(f32(r.anchor[0]) + f32(r.anchor[2]) / 2 - ax) <= 0.5, "the positioner's anchor keeps the button's middle (%v, %v)", r.anchor, ax)
	// the compositor centres the geometry on that middle: the card inside it is centred too
	gx := f32(r.anchor[0]) + f32(r.anchor[2]) / 2 - f32(r.size.x) / 2
	pos, size := platform.popup_card_of({i32(gx), 0, r.size.x, r.size.y}, desc.clear, 0)
	testing.expectf(t, abs(pos.x + size.x / 2 - ax) <= 1, "the card's middle over the button's (%v, %v)", pos.x + size.x / 2, ax)

	build(&c, .End)
	popups_sync(&b, nil, &c)
	testing.expect(t, len(log.moved) >= 1 && log.moved[len(log.moved) - 1].align == .End, "a change of alignment moves it")
	end_desc := log.moved[len(log.moved) - 1] if len(log.moved) > 0 else desc
	er := platform.popup_positioner_rects(end_desc, 0)
	// End: the geometry's right edge at the anchor rect's, the card `clear` inside it, at the button's end
	testing.expect_value(t, f32(er.anchor[0] + er.anchor[2]) - end_desc.clear, math.ceil(end_desc.anchor[0] + end_desc.anchor[2]))

	start := platform.popup_positioner_rects({anchor = {100, 0, 48, 48}, size = {300, 200}, placement = .Above, clear = 8, margin = 20}, 0)
	testing.expect_value(t, start.anchor[0] + 8, i32(100)) // Start: the card's left at the button's
	side := platform.popup_positioner_rects({anchor = {0, 300, 48, 48}, size = {300, 200}, placement = .Right, align = .Center, clear = 8, margin = 20}, 0)
	testing.expect_value(t, f32(side.anchor[1]) + f32(side.anchor[3]) / 2, f32(324)) // beside: centred down the button
}

} // when ODIN_TEST