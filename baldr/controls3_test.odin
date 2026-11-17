package baldr

@(require) import "core:strings"
@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too; behind this `when` an app does not pay for them.
// ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh check look
// inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

C3_Kind :: enum { None, Closed, Acted, Go, Num }
C3_Msg :: struct {
	kind: C3_Kind,
	i:    int,
	v:    f32,
}

@(private = "file")
on_go :: proc(e: Ev(int)) -> C3_Msg { return {kind = .Go, i = e.value} }
@(private = "file")
on_num :: proc(e: Ev(f32)) -> C3_Msg { return {kind = .Num, v = e.value} }

@(private = "file")
overlay_list :: proc(ui: ^Ui(C3_Msg)) -> [dynamic]Node {
	out := make([dynamic]Node, context.temp_allocator)
	for c := node_first(&ui.tree, ui.tree.overlay); c != NODE_NONE; c = node_next(&ui.tree, c) do append(&out, c)
	return out
}

// A toast is a polite Status at the bottom of the window that closes on
// its own after its time, stays while hovered, closes from its ×, and
// stacks above an earlier one.
@(test)
toast_shows_stacks_and_closes_on_its_own :: proc(t: ^testing.T) {
	ui: Ui(C3_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	view :: proc(ui: ^Ui(C3_Msg), n: int) {
		set_viewport(&ui.tree, {500, 400})
		begin_view(ui)
		column(ui)
		text(ui, "page")
		end(ui)
		if n >= 1 do toast(ui, "Saved", C3_Msg{kind = .Closed, i = 1}, action = "Undo", on_action = C3_Msg{kind = .Acted, i = 1}, duration_ms = 2000, key = 1)
		if n >= 2 do toast(ui, "Also this", C3_Msg{kind = .Closed, i = 2}, duration_ms = 2000, key = 2)
		end_view(ui)
		frame(&ui.tree, {500, 400})
	}
	ui_tick(&ui, 1000)
	view(&ui, 1)
	ov := overlay_list(&ui)
	testing.expect_value(t, len(ov), 1)
	td := node_get(&ui.tree, ov[0])
	testing.expect(t, td.access.role == .Status && td.access.live == .Polite && td.access.name == "Saved")
	testing.expect(t, td.abs.y + td.abs.h <= 400 - OVERLAY_EDGE_MARGIN + 0.5 && td.abs.y > 300, "at the bottom")
	testing.expect(t, abs((td.abs.x + td.abs.w / 2) - 250) < 1, "centred")
	testing.expect(t, strings.contains(access_dump(&ui.tree), "Button \"Dismiss\"") && strings.contains(access_dump(&ui.tree), "Button \"Undo\""), access_dump(&ui.tree))
	ui_tick(&ui, 2500)
	testing.expect_value(t, len(ui.msgs), 0)
	// the pointer resting on it keeps it
	pointer_move(&ui, {td.abs.x + 10, td.abs.y + 10})
	ui_tick(&ui, 3100)
	testing.expect_value(t, len(ui.msgs), 0)
	pointer_move(&ui, {10, 10})
	ui_tick(&ui, 3200)
	testing.expect_value(t, len(ui.msgs), 0)
	ui_tick(&ui, 3200 + TOAST_KEEP_MS + 50)
	testing.expect_value(t, len(ui.msgs), 1)
	testing.expect_value(t, ui.msgs[0], C3_Msg{kind = .Closed, i = 1})
	clear(&ui.msgs)
	// two: the second stacks above the first
	ui_tick(&ui, 5000)
	view(&ui, 2)
	ov = overlay_list(&ui)
	testing.expect_value(t, len(ov), 2)
	first, second := NODE_NONE, NODE_NONE
	for n in ov do if node_get(&ui.tree, n).access.name == "Saved" { first = n } else { second = n }
	a, b := node_get(&ui.tree, first).abs, node_get(&ui.tree, second).abs
	testing.expect(t, b.y + b.h <= a.y, "the later toast sits above the earlier")
	// the × closes
	x := node_get(&ui.tree, second).last
	xr := node_get(&ui.tree, x).abs
	pointer_button(&ui, .Left, true, {xr.x + xr.w / 2, xr.y + xr.h / 2})
	pointer_button(&ui, .Left, false, {xr.x + xr.w / 2, xr.y + xr.h / 2})
	testing.expect_value(t, ui.msgs[len(ui.msgs) - 1], C3_Msg{kind = .Closed, i = 2})
}

// Breadcrumbs: every part but the last is a Button sending its index; at
// phone width a long trail collapses to "… › parent › current".
@(test)
breadcrumbs_link_the_trail_and_collapse_when_narrow :: proc(t: ^testing.T) {
	ui: Ui(C3_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	parts := []string{"Home", "Pictures", "2026", "Wallpaper"}
	view :: proc(ui: ^Ui(C3_Msg), parts: []string, w: f32) -> Node {
		set_viewport(&ui.tree, {w, 200})
		begin_view(ui)
		column(ui, padding = .lg, align = .Start)
		b := breadcrumbs(ui, parts, on_go)
		end(ui)
		end_view(ui)
		frame(&ui.tree, {w, 200})
		return b
	}
	b := view(&ui, parts, 800)
	dump := access_dump(&ui.tree)
	testing.expect(t, strings.contains(dump, "Group \"Location\"") && strings.contains(dump, "Button \"Pictures\"") && strings.contains(dump, "Text \"Wallpaper\""), dump)
	testing.expect(t, !strings.contains(dump, "Button \"Wallpaper\""), "the current place is not a link")
	buttons := 0
	for c := node_first(&ui.tree, b); c != NODE_NONE; c = node_next(&ui.tree, c) do if node_get(&ui.tree, c).access.role == .Button do buttons += 1
	testing.expect_value(t, buttons, 3)
	pic := node_next(&ui.tree, node_next(&ui.tree, node_first(&ui.tree, b))) // Home, sep, Pictures
	pr := node_get(&ui.tree, pic).abs
	pointer_button(&ui, .Left, true, {pr.x + pr.w / 2, pr.y + pr.h / 2})
	pointer_button(&ui, .Left, false, {pr.x + pr.w / 2, pr.y + pr.h / 2})
	testing.expect_value(t, ui.msgs[len(ui.msgs) - 1], C3_Msg{kind = .Go, i = 1})
	b = view(&ui, parts, 400) // Compact
	dump = access_dump(&ui.tree)
	testing.expect(t, strings.contains(dump, "Button \"…\"") && strings.contains(dump, "Button \"2026\"") && !strings.contains(dump, "Button \"Home\""), dump)
	dots := node_first(&ui.tree, b)
	dr := node_get(&ui.tree, dots).abs
	pointer_button(&ui, .Left, true, {dr.x + dr.w / 2, dr.y + dr.h / 2})
	pointer_button(&ui, .Left, false, {dr.x + dr.w / 2, dr.y + dr.h / 2})
	testing.expect_value(t, ui.msgs[len(ui.msgs) - 1], C3_Msg{kind = .Go, i = 1}) // two levels up from the end
}

// A number input steps with the keys and its buttons, clamps, commits
// typed text on Enter and on blur, and reverts on Escape.
@(test)
number_input_steps_commits_and_clamps :: proc(t: ^testing.T) {
	ui: Ui(C3_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	view :: proc(ui: ^Ui(C3_Msg), v: f32) -> (outer, other: Node) {
		set_viewport(&ui.tree, {500, 200})
		begin_view(ui)
		column(ui, padding = .lg, align = .Start, gap = .md)
		outer = number_input(ui, v, on_num, min = 0, max = 10, step = 0.5, label = "Count")
		other = button(ui, "Other", C3_Msg{kind = .None})
		end(ui)
		end_view(ui)
		frame(&ui.tree, {500, 200})
		return
	}
	outer, other := view(&ui, 2)
	sp := ui.tree.spins[outer]
	field := sp.field
	fd := node_get(&ui.tree, field)
	testing.expect(t, fd.access.role == .Spin_Button && fd.access.name == "Count" && fd.access.value == 2 && fd.access.value_max == 10)
	testing.expect_value(t, string(sp.text.buf[:]), "2.0")
	testing.expect(t, strings.contains(access_dump(&ui.tree), "Button \"Increase Count\""), access_dump(&ui.tree))
	set_focus(&ui.tree, field, true)
	ui_after_events(&ui, 50) // as the run loop does after each event batch
	testing.expect(t, key_event(&ui, .Up, true, {}))
	testing.expect_value(t, ui.msgs[len(ui.msgs) - 1], C3_Msg{kind = .Num, v = 2.5})
	testing.expect_value(t, string(sp.text.buf[:]), "2.5")
	key_event(&ui, .Up, true, {.Shift})
	testing.expect_value(t, ui.msgs[len(ui.msgs) - 1], C3_Msg{kind = .Num, v = 7.5})
	key_event(&ui, .Up, true, {.Shift})
	testing.expect_value(t, ui.msgs[len(ui.msgs) - 1], C3_Msg{kind = .Num, v = 10}) // clamped
	n_before := len(ui.msgs)
	key_event(&ui, .Up, true, {})
	testing.expect_value(t, len(ui.msgs), n_before) // at the limit: nothing to send
	// type a value and commit with Enter
	text_set(&sp.text, "3.25")
	key_event(&ui, .Enter, true, {})
	testing.expect_value(t, ui.msgs[len(ui.msgs) - 1], C3_Msg{kind = .Num, v = 3.25})
	testing.expect_value(t, string(sp.text.buf[:]), "3.2") // shown with the step's decimals
	// Escape reverts a half-typed value
	text_set(&sp.text, "9")
	key_event(&ui, .Escape, true, {})
	testing.expect_value(t, string(sp.text.buf[:]), "3.2")
	// leaving the field commits
	text_set(&sp.text, "4")
	set_focus(&ui.tree, other, true)
	ui_after_events(&ui, 100)
	testing.expect_value(t, ui.msgs[len(ui.msgs) - 1], C3_Msg{kind = .Num, v = 4})
	// the − button
	minus := node_next(&ui.tree, field)
	mr := node_get(&ui.tree, minus).abs
	pointer_button(&ui, .Left, true, {mr.x + mr.w / 2, mr.y + mr.h / 2})
	pointer_button(&ui, .Left, false, {mr.x + mr.w / 2, mr.y + mr.h / 2})
	testing.expect_value(t, ui.msgs[len(ui.msgs) - 1], C3_Msg{kind = .Num, v = 3.5})
	// the app's value comes back through the view
	outer, _ = view(&ui, 3.5)
	testing.expect_value(t, string(ui.tree.spins[outer].text.buf[:]), "3.5")
	testing.expect_value(t, len(ui.diags), 0)
}

} // when ODIN_TEST