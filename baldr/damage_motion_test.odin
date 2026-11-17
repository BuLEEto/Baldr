package baldr

@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too; behind this `when` an app does not pay for them.
// ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh check look
// inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// A node that moves while it paints (a transition's slide, a layout move
// gliding) reports the strip it leaves as damage, or a window's compositor
// keeps showing it there: a window presents its damage (a popup presents whole).


@(private = "file")
DamageMotion_DMsg :: union { int }

@(private = "file")
damaged :: proc(damage: []Rect, p: [2]f32) -> bool {
	for r in damage do if p.x >= r.x && p.x < r.x + r.w && p.y >= r.y && p.y < r.y + r.h do return true
	return false
}

@(private = "file")
red_rect :: proc(t: ^Tree) -> (rect: Rect) {
	for c in draw_list(t) do if r, ok := c.(Draw_Rect); ok && r.color.r == 1 && r.color.g == 0 do rect = r.rect
	return
}

// A node gliding up into place as it fades in damages, every frame, the strip
// at its bottom it has just left; one sliding down as it fades out damages
// where it was last drawn when it goes.
@(test)
moving_nodes_damage_what_they_leave :: proc(t: ^testing.T) {
	ui: Ui(DamageMotion_DMsg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	ui.tree.theme.motion.reduce = false
	base := f64(ui.tree.theme.motion.base)
	build :: proc(ui: ^Ui(DamageMotion_DMsg), show: bool) {
		begin_view(ui)
		column(ui, padding = 20)
		if show {
			n := box(ui, width = 100, height = 40, bg = {1, 0, 0, 1}, key = 1)
			transition(ui, n, .Fade_Up, .Fade_Up)
		}
		end(ui)
		end_view(ui)
	}
	ui_tick(&ui, 100)
	build(&ui, true)
	frame(&ui.tree, {300, 300})
	take_damage(&ui.tree)
	prev := red_rect(&ui.tree)
	strips := 0
	for step in 1 ..= 6 {
		ui_tick(&ui, 100 + base * f64(step) / 5)
		frame(&ui.tree, {300, 300})
		d := take_damage(&ui.tree)
		cur := red_rect(&ui.tree)
		if prev.h > 0 && prev.y + prev.h > cur.y + cur.h + 0.5 {
			strips += 1
			testing.expectf(t, damaged(d, {prev.x + prev.w / 2, prev.y + prev.h - 0.25}), "step %d: the strip left below %v (now %v) is damaged: %v", step, prev, cur, d)
		}
		prev = cur
	}
	testing.expect(t, strips >= 3, "fixture: it glided over several frames")

	ui_tick(&ui, 2000)
	frame(&ui.tree, {300, 300})
	take_damage(&ui.tree)
	build(&ui, false) // it leaves, sliding down as it fades
	last: Rect
	went := false
	for step in 0 ..= 8 {
		ui_tick(&ui, 2000 + base * f64(step) / 6)
		frame(&ui.tree, {300, 300})
		d := take_damage(&ui.tree)
		cur := red_rect(&ui.tree)
		if cur.h == 0 && last.h > 0 {
			testing.expectf(t, damaged(d, {last.x + last.w / 2, last.y + last.h - 0.25}), "where it was last drawn, %v, is damaged when it goes: %v", last, d)
			went = true
			break
		}
		last = cur
	}
	testing.expect(t, went && last.y > 20.5, "fixture: it slid down before it went")
}

} // when ODIN_TEST