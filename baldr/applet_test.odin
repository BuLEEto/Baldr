package baldr

@(require) import "core:os"
@(require) import "core:strings"
@(require) import "core:testing"
@(require) import "baldr:platform"

// Test files are part of the package, so without this `when` every program
// that imports Baldr would type-check the whole suite too. ODIN_TEST is set
// by `odin test`; BALDR_TESTS lets ./build.sh check look inside.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// Applet surfaces inside a shell's bar.


@(private = "file")
Applet_AMsg :: enum { None, Close, Closed }

@(private = "file")
AState :: struct {}

@(test)
applets_bind_to_their_bar_or_open_as_a_window :: proc(t: ^testing.T) {
	d := Surface_Desc(Applet_AMsg){tag = 1, kind = .Applet, title = "Clock", applet = {token = "slot-1", keyboard = .None}}
	caps := platform.Caps{.Transparent, .Backdrop_Blur, .Popups, .Applets}
	out := surface_resolve(d, caps, "dev.baldr.clock")
	testing.expect_value(t, out.kind, Surface_Kind.Applet)
	testing.expect(t, out.transparent && out.backdrop == .None, "on its bar's glass: transparent, no blur of its own")
	testing.expect(t, out.applet.token == "slot-1" && out.applet.keyboard == .None, "bound with its token, keyboard as asked")

	no_applets := surface_resolve(d, caps - {.Applets}, "dev.baldr.clock")
	testing.expect_value(t, no_applets.kind, Surface_Kind.Window) // a compositor without applets: a window of its own
	testing.expect(t, !no_applets.transparent && no_applets.size == APPLET_WINDOW_SIZE, "opaque, at the applet window size")
	if os.get_env("RIKKITI_APPLET_TOKEN", context.temp_allocator) == "" {
		no_token := d
		no_token.applet.token = ""
		testing.expect_value(t, surface_resolve(no_token, caps, "dev.baldr.clock").kind, Surface_Kind.Window) // no shell started it
	}

	live := d
	live.applet.keyboard = .On_Demand
	ch := surface_changes(d, live)
	testing.expect(t, ch == {.Applet} && ch <= SURFACE_LIVE_CHANGES, "its keyboard setting changes live")
	token := d
	token.applet.token = "slot-2"
	testing.expect_value(t, surface_changes(d, token), Surface_Changes{}) // read when it opens
}

@(test)
bars_know_the_edge_they_sit_on :: proc(t: ^testing.T) {
	testing.expect_value(t, layer_edge({anchor = {.Top, .Left, .Right}}), Maybe(Edge)(.Top))
	testing.expect_value(t, layer_edge({anchor = {.Bottom, .Left, .Right}}), Maybe(Edge)(.Bottom))
	testing.expect_value(t, layer_edge({anchor = {.Left, .Top, .Bottom}}), Maybe(Edge)(.Left))
	testing.expect_value(t, layer_edge({anchor = {.Right}}), Maybe(Edge)(.Right))
	testing.expect_value(t, layer_edge({anchor = {.Top, .Left}}), Maybe(Edge){})                          // a launcher in a corner
	testing.expect_value(t, layer_edge({anchor = {.Top, .Left}, exclusive_edge = {.Left}}), Maybe(Edge)(.Left)) // a corner that reserves its left side
	testing.expect_value(t, layer_edge({}), Maybe(Edge){})
}

@(private = "file")
Applet_Popups :: struct {
	created: [dynamic]platform.Popup_Desc,
	next:    platform.Surface,
}

@(private = "file")
applet_menu :: proc(c: ^Surface_Ctx(Applet_AMsg), open: bool) -> (clock: Node) {
	ui := &c.ui
	begin_view(ui)
	column(ui, flex = 1)
	clock = button(ui, "12:05", Applet_AMsg.None)
	end(ui)
	if menu(ui, clock, open, Applet_AMsg.Close) {
		menu_item(ui, "Calendar", Applet_AMsg.None)
		if submenu(ui, "World clocks") {
			menu_item(ui, "Oslo", Applet_AMsg.None)
			end(ui)
		}
		end(ui)
	}
	end_view(ui)
	return
}

// A bar's and an applet's popups open away from the screen edge they sit
// on, whatever side the view named; popups opened from popups keep theirs.
@(test)
a_bars_popups_open_away_from_its_edge :: proc(t: ^testing.T) {
	for edge in Edge {
		log := Applet_Popups{next = 10}
		b := platform.Backend{data = &log, caps = {.Popups}}
		b.popup_create = proc(b: ^platform.Backend, d: platform.Popup_Desc) -> (platform.Surface, bool) {
			lg := (^Applet_Popups)(b.data)
			append(&lg.created, d)
			lg.next += 1
			return lg.next, true
		}
		b.popup_reposition = proc(b: ^platform.Backend, s: platform.Surface, d: platform.Popup_Desc) -> bool { return true }
		b.surface_destroy = proc(b: ^platform.Backend, s: platform.Surface) {}
		c: Surface_Ctx(Applet_AMsg)
		c.kind = .Applet
		c.surf = 1
		c.ui.surface.edge = edge
		ui_init(&c.ui)
		c.ui.tree.theme.motion.reduce = true
		set_viewport(&c.ui.tree, {160, 36} if edge == .Top || edge == .Bottom else {36, 160})

		applet_menu(&c, true)
		popups_sync(&b, nil, &c)
		testing.expectf(t, len(log.created) == 1, "%v: the menu opens on a surface of its own", edge)
		if len(log.created) == 1 {
			want := [Edge]platform.Popup_Placement{.Top = .Below, .Bottom = .Above, .Left = .Right, .Right = .Left}
			testing.expectf(t, log.created[0].placement == want[edge], "%v bar: the menu opens %v, got %v", edge, want[edge], log.created[0].placement)
			for row in c.ui.submenus do submenu_open(&c.ui, row, false)
			applet_menu(&c, true)
			popup_configured(&c, c.popups[0], {0, 40})
			popups_sync(&b, nil, &c)
			if len(log.created) == 2 do testing.expectf(t, log.created[1].placement == .Right, "%v: a submenu opens beside its row, as in any menu", edge)
		}
		popups_close_all(&b, nil, &c)
		delete(c.popups)
		ui_destroy(&c.ui)
		delete(log.created)
	}
}

@(private = "file")
clock_view :: proc(ui: ^Ui(Applet_AMsg), side: bool) -> (a, b: Node) {
	begin_view(ui)
	if side { // filling the slot, as a view centring itself in it does
		column(ui, gap = .xs, padding = .xs, align = .Center, flex = 1)
	} else {
		row(ui, gap = .sm, padding = .xs, align = .Center, flex = 1)
	}
	a = text(ui, "12" if side else "12:05")
	b = text(ui, "05" if side else "Mon 14 Sep")
	end(ui)
	end_view(ui)
	return
}

// The size hint is what the content wants along the bar: its natural length
// and the least it can take without breaking a word; the layout at the
// slot's size that follows is the one the content would have had anyway.
@(test)
applet_size_hint_measures_what_its_content_wants :: proc(t: ^testing.T) {
	ui: Ui(Applet_AMsg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	time_n, date_n := clock_view(&ui, false)
	slot := [2]f32{300, 36}
	set_viewport(&ui.tree, slot)
	least, preferred := applet_size_hint(&ui.tree, .Bottom, slot)
	th := &ui.tree.theme
	body := th.type.body.size
	w1 := ui.tree.measure_text(&ui.tree, "12:05", body, 0, .Regular, false, 0, false).x
	w2 := ui.tree.measure_text(&ui.tree, "Mon 14 Sep", body, 0, .Regular, false, 0, false).x
	pad, gap := th.space[.xs], th.space[.sm]
	testing.expectf(t, abs(preferred - (w1 + gap + w2 + 2 * pad)) < 0.5, "natural length %v, not %v", preferred, w1 + gap + w2 + 2 * pad)
	date_word := max(ui.tree.measure_text(&ui.tree, "Mon", body, 0, .Regular, false, 0, false).x, ui.tree.measure_text(&ui.tree, "14", body, 0, .Regular, false, 0, false).x, ui.tree.measure_text(&ui.tree, "Sep", body, 0, .Regular, false, 0, false).x)
	testing.expectf(t, least < preferred && abs(least - (w1 + gap + date_word + 2 * pad)) < 0.5, "the least %v keeps every word whole: the time and the date's longest word", least)

	layout(&ui.tree, slot)
	fresh: Ui(Applet_AMsg)
	ui_init(&fresh)
	defer ui_destroy(&fresh)
	f_time, f_date := clock_view(&fresh, false)
	layout(&fresh.tree, slot)
	testing.expect_value(t, node_get(&ui.tree, time_n).abs, node_get(&fresh.tree, f_time).abs) // no rect left from measuring
	testing.expect_value(t, node_get(&ui.tree, date_n).abs, node_get(&fresh.tree, f_date).abs)

	side: Ui(Applet_AMsg)
	ui_init(&side)
	defer ui_destroy(&side)
	hour, minute := clock_view(&side, true)
	thin := [2]f32{40, 200}
	set_viewport(&side.tree, thin)
	s_least, s_preferred := applet_size_hint(&side.tree, .Left, thin)
	layout(&side.tree, thin)
	md := node_get(&side.tree, minute)
	testing.expectf(t, abs(s_preferred - (md.abs.y + md.abs.h + th.space[.xs])) < 0.5 && s_least == s_preferred, "down a side bar: its height, %v", s_preferred)
	testing.expect(t, node_get(&side.tree, hour).abs.y < md.abs.y, "the lines stack")
}

// An applet sits on its bar's glass: with what the compositor measures
// there (the bar's tint included) it picks its text, but has no tint of its
// own to thicken, and without a report it keeps the theme as it is.
@(test)
applet_text_follows_its_bar_without_a_tint_of_its_own :: proc(t: ^testing.T) {
	tr: Tree
	tree_init(&tr)
	defer tree_destroy(&tr)
	th := theme_dark()
	th.glass = .Clear
	tree_theme(&tr, th)
	tree_glass(&tr, true, true, .Applet, false)
	testing.expect_value(t, tr.theme.color, tr.theme_base.color) // no report, no worst case to tint against
	tree_glass(&tr, true, true, .Applet, true)
	testing.expect(t, tree_backdrop(&tr, {0.7, 0.75, 0.8}), "the bar is light where the applet sits")
	light := theme_from_seed(th.seed, .Light)
	testing.expect_value(t, tr.theme.color.on_surface, light.color.on_surface) // dark text, with a light glow
	testing.expect(t, tr.theme.material[.Clear].glow.color.r == 1, "a light glow behind it")
	for level in Glass_Level {
		now, base := tr.theme.material[level], tr.theme_base.material[level]
		testing.expectf(t, now.panel.tint == base.panel.tint && now.popover.tint == base.popover.tint && now.window.tint == base.window.tint, "%v: no tint of its own to thicken", level)
	}
	testing.expect(t, tr.glass.popups, "its popups are glass")

	// Frosted: its own text as long as it reads; the family that does when it doesn't
	frosted := theme_light()
	tree_theme(&tr, frosted)
	testing.expect(t, tree_backdrop(&tr, {0.02, 0.03, 0.04}), "a light-themed applet on a dark bar")
	dim := theme_from_seed(frosted.seed, .Dim)
	testing.expect_value(t, tr.theme.color.on_surface, dim.color.on_surface) // light text: its own dark text can't read there
	testing.expect_value(t, tr.theme.material[.Frosted].glow, Glow{})       // and no glow off Clear
	dark := theme_dark()
	tree_theme(&tr, dark)
	testing.expect_value(t, tr.theme.color.on_surface, dark.color.on_surface) // a dark theme's own text reads there: kept
}

// The compositor closing an applet (its slot went, or its token was spent)
// ends the app, or sends on_close; either way that token doesn't open it again.
@(test)
closed_applets_stay_closed_with_their_token :: proc(t: ^testing.T) {
	backend := platform.Backend{}
	backend.surface_destroy = proc(b: ^platform.Backend, s: platform.Surface) {}
	rt: Runtime(AState, Applet_AMsg)
	rt.backend = &backend
	defer {
		delete(rt.ctxs)
		delete(rt.wanted)
		delete(rt.msgs)
		for _, token in rt.applets_closed do delete(token)
		delete(rt.applets_closed)
	}
	open :: proc(rt: ^Runtime(AState, Applet_AMsg), close: Maybe(Applet_AMsg)) {
		c := new(Surface_Ctx(Applet_AMsg))
		ui_init(&c.ui)
		c.kind = .Applet
		c.surf = 3
		c.desc = {tag = 7, kind = .Applet, on_close = close}
		c.desc.applet.token = strings.clone("slot-7")
		append(&rt.ctxs, c)
	}
	open(&rt, nil)
	testing.expect(t, close_event(&rt, {surface = 3, reason = .Compositor}, false), "with no on_close, the app ends")
	testing.expect_value(t, len(rt.ctxs), 0)
	testing.expect_value(t, rt.applets_closed[7], "slot-7")

	open(&rt, Applet_AMsg.Closed)
	testing.expect(t, !close_event(&rt, {surface = 3, reason = .Compositor}, false), "with on_close, the app decides")
	testing.expect(t, len(rt.msgs) == 1 && rt.msgs[0] == .Closed, "and hears it")

	rt.app.surfaces = proc(s: ^AState, out: ^[dynamic]Surface_Desc(Applet_AMsg)) {
		append(out, Surface_Desc(Applet_AMsg){tag = 7, kind = .Applet, applet = {token = "slot-7"}})
	}
	testing.expect(t, !sync_surfaces(&rt), "still declared with the spent token: nothing opens")
	testing.expect_value(t, len(rt.ctxs), 0)
}

} // when ODIN_TEST