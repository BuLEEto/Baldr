package baldr

@(require) import "core:strings"
@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: they sit behind this `when` so an app does not pay
// for them (see canvas_test.odin).
when ODIN_TEST || #config(BALDR_TESTS, false) {

// A text given less room than it needs: alone it wraps; with an ellipsis it
// stays one line and ends in "…"; kept to one line it is cut at its box
// rather than drawn over its neighbour.

@(private = "file")
Ovf_Msg :: union { int }

@(private = "file")
OVF_LONG :: "A sentence long enough that it can never fit in a narrow column of a table"

@(test)
a_text_with_an_ellipsis_stays_on_one_line :: proc(t: ^testing.T) {
	ui: Ui(Ovf_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	begin_view(&ui)
	column(&ui, align = .Start)
	short := text(&ui, "Short")
	plain := text(&ui, OVF_LONG, max_width = 120)
	capped := text(&ui, OVF_LONG, ellipsis = .End, max_width = 120)
	fixed := text(&ui, OVF_LONG, ellipsis = .Middle, width = 120)
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {600, 400})
	line := node_get(&ui.tree, short).abs.h
	testing.expect(t, node_get(&ui.tree, plain).abs.h > line * 2, "a max_width alone wraps")
	for n in ([]Node{capped, fixed}) {
		d := node_get(&ui.tree, n)
		k := d.kind.(Text_Kind)
		testing.expectf(t, d.abs.h == line, "one line tall: %v, a line is %v", d.abs.h, line)
		testing.expectf(t, d.abs.w <= 120, "inside its width: %v", d.abs.w)
		testing.expectf(t, strings.contains(k.display, "…"), "trimmed with an ellipsis: %q", k.display)
		testing.expectf(t, ui.tree.measure_text(&ui.tree, k.display, k.size, 0, k.weight, k.mono, k.family, k.tabular).x <= 120.01, "what it draws fits: %q", k.display)
	}
}

@(test)
a_one_line_text_is_cut_at_its_box :: proc(t: ^testing.T) {
	ui: Ui(Ovf_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	begin_view(&ui)
	column(&ui, align = .Start)
	cut := text(&ui, OVF_LONG, nowrap = true, max_width = 120)
	text(&ui, "Fits", nowrap = true, max_width = 120)
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {600, 400})
	r := node_get(&ui.tree, cut).abs
	clip: Rect
	clipped, plain_clipped := false, false
	depth := 0
	for c in draw_list(&ui.tree) {
		#partial switch v in c {
		case Draw_Clip_Push:
			depth += 1
			clip = v.rect
		case Draw_Clip_Pop:
			depth -= 1
		case Draw_Text:
			if v.str == OVF_LONG && depth > 0 && clip.x >= r.x - 0.01 && clip.x + clip.w <= r.x + r.w + 0.01 do clipped = true
			if v.str == "Fits" && depth > 0 do plain_clipped = true
		}
	}
	testing.expect(t, clipped, "the long line is clipped to its box's sides")
	testing.expect(t, !plain_clipped, "a text that fits draws no clip")
}

} // when ODIN_TEST
