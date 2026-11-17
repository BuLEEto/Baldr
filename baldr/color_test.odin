package baldr

@(require) import "core:strings"
@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too; behind this `when` an app does not pay for them.
// ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh check look
// inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

Cp_Msg :: struct { c: Color }

@(private = "file")
on_color_msg :: proc(e: Ev(Color)) -> Cp_Msg { return {e.value} }

@(private = "file")
picker_view :: proc(ui: ^Ui(Cp_Msg), c: Color) -> Node {
	set_viewport(&ui.tree, {500, 400})
	begin_view(ui)
	column(ui, padding = .lg, align = .Start)
	p := color_picker(ui, c, on_color_msg, label = "Accent")
	end(ui)
	end_view(ui)
	frame(&ui.tree, {500, 400})
	return p
}

@(private = "file")
close_colors :: proc(a, b: Color, tol: f32 = 0.02) -> bool {
	return abs(a.r - b.r) < tol && abs(a.g - b.g) < tol && abs(a.b - b.b) < tol
}

// A slider moves by its step from the keyboard, a tenth of the range by
// page, and to the ends with Home / End.
@(test)
slider_moves_by_keyboard :: proc(t: ^testing.T) {
	ui: Ui(Cp_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	set_viewport(&ui.tree, {400, 200})
	begin_view(&ui)
	column(&ui, padding = .lg, align = .Start)
	s := slider(&ui, 0.5, min = 0, max = 1, step = 0.1, label = "Volume")
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {400, 200})
	set_focus(&ui.tree, s, true)
	testing.expect(t, key_event(&ui, .Right, true, {}))
	testing.expectf(t, abs(ui.tree.sliders[s].value - 0.6) < 1e-5, "one step right: %g", ui.tree.sliders[s].value)
	key_event(&ui, .Left, true, {})
	key_event(&ui, .Left, true, {})
	testing.expectf(t, abs(ui.tree.sliders[s].value - 0.4) < 1e-5, "two steps left: %g", ui.tree.sliders[s].value)
	key_event(&ui, .Page_Up, true, {})
	testing.expectf(t, abs(ui.tree.sliders[s].value - 0.5) < 1e-5, "a tenth up: %g", ui.tree.sliders[s].value)
	key_event(&ui, .End, true, {})
	testing.expect_value(t, ui.tree.sliders[s].value, f32(1))
	key_event(&ui, .Home, true, {})
	testing.expect_value(t, ui.tree.sliders[s].value, f32(0))
	testing.expect_value(t, node_get(&ui.tree, s).access.value, f32(0))
}

// The picker shows the colour's OKLCH on three named sliders and its hex
// in a field; a slider sends the recomputed colour, Enter in the field
// sends the parsed one, and the swatch follows.
@(test)
color_picker_sliders_and_hex :: proc(t: ^testing.T) {
	ui: Ui(Cp_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	red := rgb(0xE03030)
	p := picker_view(&ui, red)
	ps := ui.tree.pickers[p]
	dump := access_dump(&ui.tree)
	testing.expect(t, strings.contains(dump, "Group \"Accent\"") && strings.contains(dump, "Slider \"Hue\"") && strings.contains(dump, "Slider \"Chroma\"") && strings.contains(dump, "Slider \"Lightness\"") && strings.contains(dump, "Text_Input \"Hex\""), dump)
	testing.expect_value(t, string(ps.hex.buf[:]), "#e03030")
	L, C, h := oklch_of(red)
	testing.expect(t, abs(ui.tree.sliders[ps.hue].value - h) < 0.01 && abs(ui.tree.sliders[ps.light].value - L) < 0.01 && abs(ui.tree.sliders[ps.chroma].value - C) < 0.01, "sliders show the colour's OKLCH")
	testing.expect(t, close_colors(node_get(&ui.tree, ps.swatch).style.bg, red), "the swatch shows it")
	testing.expect(t, ui.tree.sliders[ps.hue].track != nil, "the tracks are sampled")
	// a keyboard step on the hue slider sends a new colour with the hue moved
	set_focus(&ui.tree, ps.hue, true)
	key_event(&ui, .Right, true, {.Shift}) // 36°
	testing.expect_value(t, len(ui.msgs), 1)
	L2, C2, h2 := oklch_of(ui.msgs[0].c)
	_ = C2
	testing.expect(t, abs(L2 - L) < 0.03 && abs(h2 - (h + 36)) < 2, "the hue moved by the step, the lightness stayed (chroma may be gamut-mapped)")
	testing.expect(t, close_colors(node_get(&ui.tree, ps.swatch).style.bg, ui.msgs[0].c), "the swatch follows")
	testing.expect(t, string(ps.hex.buf[:]) != "#e03030", "the field follows")
	clear(&ui.msgs)
	// the hex field: Enter commits, Escape reverts
	set_focus(&ui.tree, ps.field, true)
	ui_after_events(&ui, 10)
	text_set(&ps.hex, "#00ff00")
	key_event(&ui, .Enter, true, {})
	testing.expect_value(t, len(ui.msgs), 1)
	testing.expect(t, close_colors(ui.msgs[0].c, rgb(0x00FF00)), "Enter sends the parsed colour")
	testing.expect(t, abs(ui.tree.sliders[ps.hue].value - 142) < 3, "the hue slider moved to green")
	text_set(&ps.hex, "not a colour")
	key_event(&ui, .Enter, true, {})
	testing.expect_value(t, len(ui.msgs), 1)
	testing.expect_value(t, string(ps.hex.buf[:]), "#00ff00")
	text_set(&ps.hex, "#123")
	key_event(&ui, .Escape, true, {})
	testing.expect_value(t, string(ps.hex.buf[:]), "#00ff00")
	// the app's colour comes back through the view; a changed one moves everything
	clear(&ui.msgs)
	set_focus(&ui.tree, NODE_NONE, false)
	ui_after_events(&ui, 20)
	picker_view(&ui, rgb(0x2050F0))
	testing.expect_value(t, string(ps.hex.buf[:]), "#2050f0")
	Lb, _, hb := oklch_of(rgb(0x2050F0))
	testing.expect(t, abs(ui.tree.sliders[ps.hue].value - hb) < 0.01 && abs(ui.tree.sliders[ps.light].value - Lb) < 0.01)
	c3, ok3 := color_parse_hex("#abc")
	testing.expect(t, ok3 && close_colors(c3, rgb(0xAABBCC)))
}

// The chroma slider reaches both ends and the hue stays put at zero
// chroma: the colour is gamut-mapped, the thumbs are not pulled back.
@(test)
color_picker_sliders_keep_their_places :: proc(t: ^testing.T) {
	ui: Ui(Cp_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	p := picker_view(&ui, rgb(0xE03030))
	ps := ui.tree.pickers[p]
	h0 := ui.tree.sliders[ps.hue].value
	set_focus(&ui.tree, ps.chroma, true)
	key_event(&ui, .End, true, {})
	testing.expect_value(t, ui.tree.sliders[ps.chroma].value, PICKER_CHROMA_MAX)
	testing.expect(t, abs(ui.tree.sliders[ps.hue].value - h0) < 0.01, "the hue slider stayed")
	key_event(&ui, .Home, true, {})
	testing.expect_value(t, ui.tree.sliders[ps.chroma].value, f32(0))
	testing.expect(t, abs(ui.tree.sliders[ps.hue].value - h0) < 0.01, "…and stays at zero chroma (a grey)")
	c := ui.msgs[len(ui.msgs) - 1].c
	testing.expect(t, abs(c.r - c.g) < 0.02 && abs(c.g - c.b) < 0.02, "zero chroma is a grey")
	key_event(&ui, .Right, true, {}) // one hundredth up: still moves from zero
	testing.expect(t, ui.tree.sliders[ps.chroma].value > 0)
}

} // when ODIN_TEST