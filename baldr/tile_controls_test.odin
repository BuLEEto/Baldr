package baldr

@(require) import "core:strings"
@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too; behind this `when` an app does not pay for them.
// ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh check look
// inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// The controls a desktop shell's Control Centre tiles are made of.


@(private = "file")
TileControls_TMsg :: union { int }

// The tile fills are the content colour, faint for tiles and strong for
// tracks and switched-off toggles on a tile, at the design's tokens (4.5 %
// and 8 % on Light, 7 % and 12 % on Dim and Dark, as a browser blends them)
// converted against the popover's glass: more than the token
// where the ink is dark on light glass, less where it is light on dark;
// more under high contrast. On a Clear glass popover whose text flips family
// they are that family's.
@(test)
tile_fills_follow_the_content_colour :: proc(t: ^testing.T) {
	tokens := GLASS_TOKENS
	for mode in Theme_Mode {
		th := theme_from_seed(BALDR_BLUE, mode)
		c := th.color
		tok := tokens[mode]
		glass := th.material[.Frosted].popover.tint
		faint := glass_token_alpha(c.on_surface.rgb, tok.fill, glass)
		strong := glass_token_alpha(c.on_surface.rgb, tok.fill_strong, glass, under_ink = c.on_surface.rgb, under = faint, under_token = tok.fill)
		testing.expectf(t, c.fill == with_alpha(c.on_surface, faint), "%v: the faint fill is the content colour at the converted %v: %v", mode, tok.fill, c.fill)
		testing.expectf(t, c.fill_strong == with_alpha(c.on_surface, strong), "%v: the strong fill at the converted %v: %v", mode, tok.fill_strong, c.fill_strong)
		if mode == .Light {
			testing.expect(t, c.fill.a > tok.fill && c.fill_strong.a > tok.fill_strong, "Light: dark ink on light glass takes more than its token")
		} else {
			testing.expectf(t, c.fill.a < tok.fill && c.fill_strong.a < tok.fill_strong, "%v: light ink on dark glass takes less than its token", mode)
		}
		hc := theme_from_seed(BALDR_BLUE, mode, .High).color
		testing.expectf(t, hc.fill.a > c.fill.a && hc.fill_strong.a > c.fill_strong.a, "%v: high contrast fills more", mode)
	}

	th := theme_from_seed(BALDR_BLUE, .Dim)
	th.glass = .Clear
	families := [2]Color_Roles{theme_from_seed(BALDR_BLUE, .Light).color, theme_from_seed(BALDR_BLUE, .Dim).color}
	glass_legible(&th, .Popover, {min = 0.85, avg = 0.9, max = 0.95}, &families) // a bright desktop behind the popover
	testing.expect(t, luminance(th.color.on_surface) < 0.2, "fixture: the text flipped to dark")
	// the fills take the flipped family's ink…
	testing.expect_value(t, th.color.fill.rgb, families[0].fill.rgb)
	testing.expect_value(t, th.color.fill_strong.rgb, families[0].fill_strong.rgb)
	// …and at least its alpha: they are solved for this surface's own
	// backdrop afterwards, which only ever asks for more
	testing.expect(t, th.color.fill.a >= families[0].fill.a)
	testing.expect(t, th.color.fill_strong.a >= families[0].fill_strong.a)
}

// A segmented control's segments can carry an icon before their label: in
// the label's colour, decorative, the segment still named by its label.
@(test)
segmented_segments_take_icons :: proc(t: ^testing.T) {
	ui: Ui(TileControls_TMsg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	begin_view(&ui)
	g := segmented(&ui, 1, {"Light", "Dim", "Dark"}, icons = {.Sun, .None, .Moon}, label = "Appearance")
	end_view(&ui)
	frame(&ui.tree, {400, 60})
	th := &ui.tree.theme
	items := ui.tree.choices[g].items[:]
	testing.expect_value(t, len(items), 3)
	if len(items) != 3 do return
	parts :: proc(t: ^Tree, item: Node) -> (icon, label: Node) {
		icon, label = NODE_NONE, NODE_NONE
		for c := node_get(t, item).first; c != NODE_NONE; c = node_get(t, c).next {
			switch k in node_get(t, c).kind {
			case Custom_Kind: if k.paint == paint_icon do icon = c
			case Text_Kind:   label = c
			case Box_Kind, Text_Input_Kind:
			}
		}
		return
	}
	sun, sun_label := parts(&ui.tree, items[0])
	dim_icon, _ := parts(&ui.tree, items[1])
	moon, moon_label := parts(&ui.tree, items[2])
	testing.expect(t, sun != NODE_NONE && moon != NODE_NONE, "the Light and Dark segments show their icons")
	testing.expect_value(t, dim_icon, NODE_NONE) // .None: a segment without one
	if sun == NODE_NONE || moon == NODE_NONE do return
	testing.expect(t, node_get(&ui.tree, sun).abs.x < node_get(&ui.tree, sun_label).abs.x, "the icon goes before the label")
	testing.expect_value(t, node_get(&ui.tree, sun).style.fg, th.color.on_surface_muted) // an unpicked segment's colour
	testing.expect_value(t, node_get(&ui.tree, moon).style.fg, node_get(&ui.tree, moon_label).style.fg)
	testing.expect_value(t, node_get(&ui.tree, sun).access.role, Role.None)
	testing.expect_value(t, node_get(&ui.tree, items[0]).access.name, "Light")
	testing.expect(t, lint(&ui.tree) == 0)
}

@(private = "file")
color_close :: proc(a, b: Color) -> bool {
	return abs(a.r - b.r) < 1e-4 && abs(a.g - b.g) < 1e-4 && abs(a.b - b.b) < 1e-4 && abs(a.a - b.a) < 1e-4
}

// the Draw_Rect covering `r` exactly, and the Draw_Icon of `icon`, in the draw list.
@(private = "file")
drawn_at :: proc(t: ^Tree, r: Rect, icon: Icon) -> (rect: Draw_Rect, glyph: Draw_Icon, has_rect, has_icon: bool) {
	for c in draw_list(t) {
		#partial switch v in c {
		case Draw_Rect: if v.rect == r do rect, has_rect = v, true
		case Draw_Icon: if v.icon == icon do glyph, has_icon = v, true
		}
	}
	return
}

// An icon_toggle is a round Toggle_Button named by its label. Off it is the
// strong fill with the icon in the content colour; on, eased, the accent
// with the icon in the on-accent colour. A click or Space flips it and says
// the new value; disabled it dims and doesn't flip.
@(test)
icon_toggles_flip_and_show_it :: proc(t: ^testing.T) {
	ui: Ui(TileControls_TMsg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	view :: proc(ui: ^Ui(TileControls_TMsg), on: bool, disabled := false) -> Node {
		begin_view(ui)
		row(ui, padding = .md)
		n := icon_toggle(ui, .Wifi, on, "Wi-Fi", proc(e: Ev(bool)) -> TileControls_TMsg {
			if e.value do return TileControls_TMsg(1)
			return TileControls_TMsg(0)
		}, disabled = disabled)
		end(ui)
		end_view(ui)
		frame(&ui.tree, {200, 100})
		return n
	}
	th := &ui.tree.theme
	n := view(&ui, false)
	d := node_get(&ui.tree, n)
	testing.expect(t, d.abs.w == ICON_TOGGLE_SIZE && d.abs.h == ICON_TOGGLE_SIZE, "34 px across")
	testing.expect_value(t, d.access.role, Role.Toggle_Button)
	testing.expect_value(t, d.access.name, "Wi-Fi")
	testing.expect(t, .Pressed not_in d.access.states, "off")
	testing.expect(t, lint(&ui.tree) == 0)
	circle, glyph, has_circle, has_glyph := drawn_at(&ui.tree, d.abs, .Wifi)
	testing.expect(t, has_circle && has_glyph, "the circle and its icon")
	testing.expect(t, circle.radius == ICON_TOGGLE_SIZE / 2 && color_close(circle.color, th.color.fill_strong), "off: a round strong fill")
	testing.expect(t, color_close(glyph.color, th.color.on_surface) && glyph.size == 17, "the icon, half its size, in the content colour")

	centre := [2]f32{d.abs.x + d.abs.w / 2, d.abs.y + d.abs.h / 2}
	pointer_button(&ui, .Left, true, centre)
	pointer_button(&ui, .Left, false, centre)
	testing.expect(t, len(ui.msgs) == 1 && ui.msgs[0].(int) == 1, "a click turns it on")
	clear(&ui.msgs)
	pointer_move(&ui, {0, 90}) // the pointer leaves: no hover layer once it fades
	n = view(&ui, true)
	d = node_get(&ui.tree, n)
	testing.expect(t, .Pressed in d.access.states, "on")
	ui_tick(&ui, 5000) // the fill eases to the accent, the hover layer away
	frame(&ui.tree, {200, 100})
	ui_tick(&ui, 10_000)
	frame(&ui.tree, {200, 100})
	circle, glyph, _, _ = drawn_at(&ui.tree, d.abs, .Wifi)
	testing.expect(t, color_close(circle.color, th.color.primary) && color_close(glyph.color, th.color.on_primary), "on: the accent, with the icon on it")

	set_focus(&ui.tree, n, true)
	testing.expect(t, key_event(&ui, .Space, true, {}))
	testing.expect(t, len(ui.msgs) == 1 && ui.msgs[0].(int) == 0, "Space turns it off")
	clear(&ui.msgs)

	n = view(&ui, true, disabled = true)
	d = node_get(&ui.tree, n)
	pointer_button(&ui, .Left, true, centre)
	pointer_button(&ui, .Left, false, centre)
	testing.expect_value(t, len(ui.msgs), 0) // disabled: no flip
	frame(&ui.tree, {200, 100})
	circle, _, _, _ = drawn_at(&ui.tree, d.abs, .Wifi)
	testing.expect(t, abs(circle.color.a - th.color.primary.a * th.state.disabled_alpha) < 1e-4, "and dims")
}

// A Large slider is a 30 px pill: the accent fills it up to and under a
// round knob and its icon sits inside the filled start in the on-accent
// colour (over the knob at the start, in the colour that reads on the
// knob). Pointer and keys set it as any slider.
@(test)
large_sliders_are_a_pill_with_an_icon :: proc(t: ^testing.T) {
	ui: Ui(TileControls_TMsg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	view :: proc(ui: ^Ui(TileControls_TMsg), v: f32, icon: Icon) -> Node {
		begin_view(ui)
		row(ui, padding = .md)
		n := slider(ui, v, 0, 1, proc(e: Ev(f32)) -> TileControls_TMsg { return TileControls_TMsg(int(e.value * 100 + 0.5)) }, width = 300, size = .Large, icon = icon, label = "Volume")
		end(ui)
		end_view(ui)
		frame(&ui.tree, {400, 100})
		return n
	}
	th := &ui.tree.theme
	n := view(&ui, 0.62, .Volume_2)
	d := node_get(&ui.tree, n)
	r := d.abs
	testing.expect(t, r.w == 300 && r.h == SLIDER_LARGE_H, "300 by 30")
	testing.expect_value(t, d.access.role, Role.Slider)
	testing.expect_value(t, d.access.name, "Volume")
	testing.expect_value(t, d.access.value, 0.62)
	kx := r.x + (r.w - r.h) * 0.62
	track, glyph, has_track, has_glyph := drawn_at(&ui.tree, r, .Volume_2)
	testing.expect(t, has_track && track.radius == 15 && color_close(track.color, th.color.fill_strong), "a pill in the strong fill")
	fill, _, has_fill, _ := drawn_at(&ui.tree, {r.x, r.y, kx + r.h - r.x, r.h}, .None)
	testing.expect(t, has_fill && color_close(fill.color, th.color.primary), "the accent up to and under the knob")
	knob, _, has_knob, _ := drawn_at(&ui.tree, {kx, r.y, r.h, r.h}, .None)
	testing.expect(t, has_knob && knob.radius == 15, "a round knob")
	testing.expect(t, has_glyph && color_close(glyph.color, th.color.on_primary) && glyph.pos.x < kx, "the icon inside the filled start, on the accent")

	p := [2]f32{r.x + r.h / 2 + (r.w - r.h) * 0.25, r.y + r.h / 2}
	pointer_button(&ui, .Left, true, p)
	pointer_button(&ui, .Left, false, p)
	testing.expect(t, len(ui.msgs) >= 1 && ui.msgs[0].(int) == 25, "a press a quarter along picks 0.25")
	clear(&ui.msgs)
	set_focus(&ui.tree, n, true)
	testing.expect(t, key_event(&ui, .End, true, {}))
	testing.expect(t, len(ui.msgs) == 1 && ui.msgs[0].(int) == 100, "End: all the way")
	clear(&ui.msgs)

	n = view(&ui, 0, .Volume_X) // muted: the app's other icon
	_, glyph, _, has_glyph = drawn_at(&ui.tree, node_get(&ui.tree, n).abs, .Volume_X)
	want := th.color.surface if th.dark else th.color.on_surface
	testing.expect(t, has_glyph && color_close(glyph.color, want), "at 0 the knob is over the icon, which reads on the knob")

	// given more height than its pill (flex in a column), the pill and knob keep theirs, centred
	begin_view(&ui)
	column(&ui, height = 100)
	tall := slider(&ui, 0.5, 0, 1, width = 300, flex = 1, size = .Large, icon = .Sun, label = "Brightness")
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {400, 100})
	td := node_get(&ui.tree, tall).abs
	testing.expectf(t, td.h > SLIDER_LARGE_H, "fixture: laid out taller than its pill: %v", td.h)
	pill := Rect{td.x, td.y + (td.h - SLIDER_LARGE_H) / 2, td.w, SLIDER_LARGE_H}
	_, sun, has_pill, has_sun := drawn_at(&ui.tree, pill, .Sun)
	testing.expect(t, has_pill, "the pill stays 30 px, centred")
	testing.expect(t, has_sun && sun.size == 16 && sun.pos.y > pill.y && sun.pos.y + sun.size < pill.y + pill.h, "the icon stays its size, inside the pill")
}

// A button can show several icons side by side (a Control Centre's bar
// button: Wi-Fi, sound, battery), in order, in its content colour and
// decorative, the button named by its label; button_options sizes them all.
@(test)
a_button_shows_several_icons :: proc(t: ^testing.T) {
	ui: Ui(TileControls_TMsg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	view :: proc(ui: ^Ui(TileControls_TMsg), size: f32) -> Node {
		begin_view(ui)
		row(ui, padding = .md)
		b := button(ui, "Control Centre", TileControls_TMsg(1), variant = .Ghost, icons = {.Wifi, .Volume_2, .Battery_Medium}, icon_only = true)
		if size > 0 do button_options(ui, b, icon_size = size)
		end(ui)
		end_view(ui)
		frame(&ui.tree, {300, 100})
		return b
	}
	b := view(&ui, 0)
	bd := node_get(&ui.tree, b)
	testing.expect_value(t, bd.access.name, "Control Centre")
	seen: [dynamic]Node
	defer delete(seen)
	for c := bd.first; c != NODE_NONE; c = node_get(&ui.tree, c).next do append(&seen, c)
	testing.expect_value(t, len(seen), 3)
	if len(seen) != 3 do return
	want := [3]Icon{.Wifi, .Volume_2, .Battery_Medium}
	for c, i in seen {
		cd := node_get(&ui.tree, c)
		testing.expectf(t, Icon(cd.tag) == want[i], "icon %d is %v: %v", i, want[i], Icon(cd.tag))
		testing.expect_value(t, cd.abs.w, ICON_SIZE)
		testing.expect_value(t, cd.style.fg, ui.tree.theme.color.primary) // a Ghost button's content colour
		testing.expect_value(t, cd.access.role, Role.None)
		if i > 0 do testing.expect(t, cd.abs.x > node_get(&ui.tree, seen[i - 1]).abs.x, "side by side, in order")
	}
	testing.expect(t, lint(&ui.tree) == 0)

	b = view(&ui, 20)
	for c := node_get(&ui.tree, b).first; c != NODE_NONE; c = node_get(&ui.tree, c).next {
		testing.expect_value(t, node_get(&ui.tree, c).abs.w, 20) // all of them
	}
}

// Rearranging tiles: in a wrap of mixed 1-, 2- and 4-wide tiles, a
// dragged tile relinks among its siblings as the pointer crosses another, so
// the grid reflows around it (a wide tile that no longer fits its line moves
// to the next), and the drop says which tile it landed by, and on which side.
@(test)
tiles_reorder_in_a_wrapping_grid_of_mixed_widths :: proc(t: ^testing.T) {
	ui: Ui(TileControls_TMsg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	GRID_W :: f32(352)
	unit := (GRID_W - 3 * ui.tree.theme.space[.sm]) / 4
	widths := [7]f32{2, 2, 1, 1, 1, 1, 4}
	view :: proc(ui: ^Ui(TileControls_TMsg), widths: [7]f32, unit: f32) -> (tiles: [7]Node) {
		begin_view(ui)
		wrap(ui, gap = .sm, width = GRID_W)
		for w, i in widths {
			tile := row(ui, width = w * unit + (w - 1) * ui.tree.theme.space[.sm], height = 60, bg = ui.tree.theme.color.fill, radius = 16, key = u64(i + 1))
			text(ui, "tile")
			end(ui)
			draggable(ui, tile, "tile", tag = u64(i + 1))
			drop_target(ui, tile, proc(e: Ev(Drop)) -> TileControls_TMsg {
				return TileControls_TMsg(int(e.value.tag) * 100 + int(e.tag) * 10 + (1 if e.value.position == .Before else 0))
			}, accepts = "tile", positions = {.Before, .After}, tag = u64(i + 1))
			tiles[i] = tile
		}
		end(ui)
		end_view(ui)
		frame(&ui.tree, {400, 400})
		return
	}
	tiles := view(&ui, widths, unit)
	a, b, c := node_get(&ui.tree, tiles[0]).abs, node_get(&ui.tree, tiles[1]).abs, node_get(&ui.tree, tiles[2]).abs
	testing.expect(t, a.y == b.y && c.y > a.y, "fixture: two wide tiles on the first line, the small ones under them")

	start := [2]f32{c.x + 20, c.y + 20}
	ui.pointer.press_serial = 7
	pointer_button(&ui, .Left, true, start)
	pointer_move(&ui, start + {10, 0}) // past the threshold: the tile is up
	testing.expect(t, ui.drag.active, "the small tile is picked up")
	pointer_move(&ui, {a.x + 10, a.y + 20}) // over the first wide tile's start
	frame(&ui.tree, {400, 400})
	first := node_get(&ui.tree, node_get(&ui.tree, node_parent(&ui.tree, tiles[0])).first).key
	testing.expect_value(t, first, u64(3)) // relinked before it
	a, b, c = node_get(&ui.tree, tiles[0]).abs, node_get(&ui.tree, tiles[1]).abs, node_get(&ui.tree, tiles[2]).abs
	testing.expect(t, c.x < a.x && c.y == a.y, "the small tile now leads the first line")
	testing.expect(t, b.y > a.y, "the second wide tile no longer fits and reflows to the next line")

	pointer_button(&ui, .Left, false, {a.x + 10, a.y + 20})
	landed := false
	for m in ui.msgs do if m.(int) == 3 * 100 + 1 * 10 + 1 do landed = true
	testing.expect(t, landed, "the drop: tile 3 before tile 1")
}

// A segmented control given a width keeps its segments equal while each
// fits an equal share. When one can't ("Performance" beside "Saver"), the
// segments that need more keep their content's width and the rest share
// what is left alike; with less room their padding tightens alike, and only
// then are the widest labels cut to one width, ending in "…" and still
// named whole. Hugging, it is as wide as its segments want.
@(test)
segmented_segments_share_the_width_by_what_they_hold :: proc(t: ^testing.T) {
	ui: Ui(TileControls_TMsg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	Seg :: struct { w, held: [3]f32, cut: [3]bool, names: [3]string }
	build :: proc(ui: ^Ui(TileControls_TMsg), labels: []string, width: f32) -> (s: Seg) {
		begin_view(ui)
		g := segmented(ui, 1, labels, icons = {.Leaf, .Gauge, .Zap}, label = "Power mode", width = width)
		end_view(ui)
		frame(&ui.tree, {800, 80})
		for item, i in ui.tree.choices[g].items {
			d := node_get(&ui.tree, item)
			s.w[i], s.names[i] = d.abs.w, d.access.name
			x0, x1: f32 = max(f32), 0
			for c := d.first; c != NODE_NONE; c = node_get(&ui.tree, c).next {
				cd := node_get(&ui.tree, c)
				x0, x1 = min(x0, cd.abs.x), max(x1, cd.abs.x + cd.abs.w)
				if tk, ok := cd.kind.(Text_Kind); ok do s.cut[i] = len(tk.display) > 0
			}
			s.held[i] = x1 - x0 // its icon, gap and label
		}
		return
	}
	near :: proc(a, b: f32) -> bool { return abs(a - b) < 0.01 }
	power := []string{"Saver", "Balanced", "Performance"}
	slack := 2 * (ui.tree.theme.space[.md] - ui.tree.theme.space[.xs])
	PAD :: 6 // the track's 3 px either side

	hug := build(&ui, power, 0)
	want := hug.w
	testing.expect(t, want[0] < want[1] && want[1] < want[2], "fixture: Performance wants the most")
	testing.expect(t, hug.cut == {}, "hugging: nothing cut")
	for i in 0 ..< 3 do testing.expectf(t, near(want[i], hug.held[i] + 2 * ui.tree.theme.space[.md]), "hugging: segment %d is what it holds with md padding either side: %v", i, want[i])

	even := build(&ui, {"Light", "Dim", "Dark"}, 3 * want[2] + PAD)
	testing.expect(t, near(even.w[0], even.w[1]) && near(even.w[1], even.w[2]) && near(even.w[0], want[2]), "each fits an equal share: equal")

	inner := want[0] + want[1] + want[2] + 20
	testing.expect(t, 3 * want[2] > inner, "fixture: equal thirds can't hold Performance")
	fit := build(&ui, power, inner + PAD)
	testing.expect(t, near(fit.w[0] + fit.w[1] + fit.w[2], inner) && fit.cut == {}, "the whole width, nothing cut")
	for i in 0 ..< 3 do testing.expectf(t, fit.w[i] >= want[i] - 0.01, "segment %d keeps its width: %v of %v", i, fit.w[i], want[i])
	testing.expect(t, near(fit.w[2], want[2]) && fit.w[0] > want[0] + 0.5, "Performance keeps its width; the rest share what is left")
	if fit.w[1] > want[1] + 0.01 do testing.expect(t, near(fit.w[0], fit.w[1]), "…alike")

	tight := build(&ui, power, want[0] + want[1] + want[2] - 3 * slack / 2 + PAD)
	testing.expect(t, tight.cut == {}, "tighter padding, nothing cut")
	for i in 0 ..< 3 do testing.expectf(t, near(tight.w[i], want[i] - slack / 2), "segment %d gives up padding alike: %v", i, tight.w[i])

	content := [3]f32{want[0] - slack, want[1] - slack, want[2] - slack}
	narrow := build(&ui, power, content[0] + content[1] + content[2] - 30 + PAD)
	testing.expect(t, near(narrow.w[0], content[0]) && !narrow.cut[0], "Saver keeps its label")
	testing.expect(t, near(narrow.w[1], narrow.w[2]) && narrow.cut[1] && narrow.cut[2], "the widest are cut to one width, with …")
	testing.expect(t, narrow.names == {"Saver", "Balanced", "Performance"}, "and are still named whole")
	testing.expect(t, lint(&ui.tree) == 0)
}

// A Large slider's icon can be a toggle of its own, a mute: a
// Toggle_Button named by icon_label over the icon's circle, Pressed while
// muted, a Tab stop before the track. A click, Enter or Space on it sends
// on_icon; a press on the track beside it still sets the value. Assistive
// technology meets the two as siblings; the slider returned is the track.
@(test)
slider_icon_is_its_own_toggle :: proc(t: ^testing.T) {
	ui: Ui(TileControls_TMsg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	ui.tree.theme.motion.reduce = true
	view :: proc(ui: ^Ui(TileControls_TMsg), muted: bool) -> (track: Node) {
		set_viewport(&ui.tree, {400, 120})
		begin_view(ui)
		column(ui, padding = .lg)
		track = slider(ui, 0.6, 0, 1, proc(e: Ev(f32)) -> TileControls_TMsg { return TileControls_TMsg(int(e.value * 100 + 0.5)) }, width = 300, size = .Large,
			icon = .Volume_X if muted else .Volume_2, label = "Volume", on_icon = TileControls_TMsg(-1), icon_label = "Mute", icon_pressed = muted)
		end(ui)
		end_view(ui)
		frame(&ui.tree, {400, 120})
		return
	}
	track := view(&ui, false)
	td := node_get(&ui.tree, track)
	toggle := td.next
	testing.expect(t, td.access.role == .Slider && td.access.name == "Volume", "the slider returned is the track")
	if toggle == NODE_NONE {
		testing.expect(t, false, "the icon's toggle follows the track")
		return
	}
	od := node_get(&ui.tree, toggle)
	testing.expect(t, od.access.role == .Toggle_Button && od.access.name == "Mute" && .Pressed not_in od.access.states, "a Toggle_Button named Mute, not pressed")
	testing.expect_value(t, od.abs, Rect{td.abs.x, td.abs.y, SLIDER_LARGE_H, SLIDER_LARGE_H}) // over the icon's circle
	testing.expect_value(t, td.abs.w, 300)

	testing.expect(t, focus_next(&ui.tree) && ui.tree.focus == toggle, "Tab reaches the mute first")
	testing.expect(t, focus_next(&ui.tree) && ui.tree.focus == track, "then the track")

	press :: proc(ui: ^Ui(TileControls_TMsg), p: [2]f32) {
		pointer_button(ui, .Left, true, p)
		pointer_button(ui, .Left, false, p)
	}
	clear(&ui.msgs)
	press(&ui, {od.abs.x + od.abs.w / 2, od.abs.y + od.abs.h / 2})
	testing.expectf(t, len(ui.msgs) == 1 && ui.msgs[0] == TileControls_TMsg(-1), "a click on the icon mutes: %v", ui.msgs[:])
	clear(&ui.msgs)
	press(&ui, {td.abs.x + 250, td.abs.y + td.abs.h / 2})
	got, is_level := ui.msgs[0].(int) if len(ui.msgs) > 0 else 0, len(ui.msgs) > 0
	testing.expectf(t, is_level && got > 60 && got != -1, "a press on the track sets the value: %v", ui.msgs[:])
	for key in ([]Key{.Enter, .Space}) {
		clear(&ui.msgs)
		set_focus(&ui.tree, toggle, true)
		key_event(&ui, key, true, {})
		key_event(&ui, key, false, {})
		testing.expectf(t, len(ui.msgs) == 1 && ui.msgs[0] == TileControls_TMsg(-1), "%v on the icon mutes once: %v", key, ui.msgs[:])
	}

	view(&ui, true)
	testing.expect(t, .Pressed in node_get(&ui.tree, toggle).access.states, "Pressed while muted")
	dump := access_dump(&ui.tree)
	testing.expect(t, strings.contains(dump, "Toggle_Button \"Mute\"") && strings.contains(dump, "Slider \"Volume\""), dump)
	testing.expect(t, lint(&ui.tree) == 0)
}

} // when ODIN_TEST