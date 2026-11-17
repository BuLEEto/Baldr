package baldr

@(require) import "core:encoding/base64"
@(require) import "core:fmt"
@(require) import "core:os"
@(require) import "core:strings"
@(require) import "core:testing"
@(require) import "baldr:gpu"
@(require) import runa "baldr:third_party/runa"

// Test files are part of the package, so without this `when` every program
// that imports Baldr would type-check the whole suite too. ODIN_TEST is set
// by `odin test`; BALDR_TESTS lets ./build.sh check look inside.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// A 2 × 1 PNG: a red pixel, then a blue one.
@(private = "file")
RED_BLUE_PNG :: "iVBORw0KGgoAAAANSUhEUgAAAAIAAAABCAYAAAD0In+KAAAADklEQVR4nGP4z8AAQv8BD/kD/YURmXYAAAAASUVORK5CYII="

// theme_icon_test_tree writes two icon themes (Test and Other) and a pixmaps
// directory under a fresh root, and returns the root.
@(private = "file")
theme_icon_test_tree :: proc(t: ^testing.T, tag: string) -> string {
	tmp := os.get_env("TMPDIR", context.temp_allocator)
	if tmp == "" do tmp = "/tmp"
	root := fmt.tprintf("%s/baldr-theme-icons-%s-%d", tmp, tag, t.seed)
	_ = os.remove_all(root)
	index :: "[Icon Theme]\nName=%s\nDirectories=scalable/apps\n\n[scalable/apps]\nSize=16\nMinSize=8\nMaxSize=512\nType=Scalable\n"
	svg :: `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16">`
	png, _ := base64.decode(RED_BLUE_PNG, allocator = context.temp_allocator)
	files := [][2]string{
		{"icons/Test/index.theme", fmt.tprintf(index, "Test")},
		{"icons/Test/scalable/apps/app.svg", svg + `<rect width="16" height="16" fill="#ff0000"/></svg>`},
		{"icons/Test/scalable/apps/signal-symbolic.svg", svg + `<path d="M0 0H16V16H0Z" fill="#bebebe"/></svg>`},
		{"icons/Test/scalable/apps/badge-symbolic.svg", svg + `<rect width="8" height="16" fill="#bebebe"/><rect x="8" width="8" height="16" fill="#bebebe" class="error"/></svg>`},
		{"icons/Test/scalable/apps/kde.svg", svg + `<style>.ColorScheme-Text { color:#444444; }</style><rect width="16" height="16" style="fill:currentColor" class="ColorScheme-Text"/></svg>`},
		{"icons/Test/scalable/apps/pic.png", string(png)},
		{"icons/Test/scalable/apps/tray-symbolic.png", string(png)},
		{"icons/Other/index.theme", fmt.tprintf(index, "Other")},
		{"icons/Other/scalable/apps/app.svg", svg + `<rect width="16" height="16" fill="#0000ff"/></svg>`},
		{"pixmaps/old.xpm", `"2 1 2 1", "r c #FF0000", "b c #0000FF", "rb"`},
	}
	for f in files {
		path := fmt.tprintf("%s/%s", root, f[0])
		_ = os.make_directory_all(path[:strings.last_index_byte(path, '/')])
		err := os.write_entire_file(path, transmute([]u8)f[1])
		testing.expectf(t, err == nil, "wrote %s: %v", path, err)
	}
	return root
}

@(private = "file")
theme_icon_test_search :: proc(ld: ^Icon_Loader, root: string) {
	bases := [1]string{fmt.tprintf("%s/icons", root)}
	pixmaps := [1]string{fmt.tprintf("%s/pixmaps", root)}
	icon_loader_search(ld, bases[:], pixmaps[:])
}

@(private = "file")
theme_icon_test_px :: proc(r: Icon_Result, x, y: int) -> [4]int {
	if r.mask do return {0, 0, 0, int(r.pixels[y * r.px + x])}
	i := (y * r.px + x) * 4
	return {int(r.pixels[i]), int(r.pixels[i + 1]), int(r.pixels[i + 2]), int(r.pixels[i + 3])}
}

@(test)
theme_icon_loader_decodes_by_kind :: proc(t: ^testing.T) {
	root := theme_icon_test_tree(t, "kinds")
	defer os.remove_all(root)
	ld: Icon_Loader
	icon_loader_init(&ld, context.allocator)
	defer icon_loader_destroy(&ld)
	theme_icon_test_search(&ld, root)
	colors := Svg_Colors{text = rgb(0x336699), negative = rgb(0xaa0000)}
	resolve :: proc(ld: ^Icon_Loader, name: string, colors: Svg_Colors) -> Icon_Result {
		a := ld.allocator
		req := Icon_Request{key = strings.clone(name, a), name = strings.clone(name, a), dir = strings.clone("", a), theme = strings.clone("Test", a), size = 16, scale = 1, px = 16, colors = colors}
		defer icon_request_free(ld, &req)
		return icon_loader_resolve(ld, &req)
	}
	near :: proc(got, want: [4]int) -> bool {
		for k in 0 ..< 4 do if abs(got[k] - want[k]) > 1 do return false
		return true
	}

	app := resolve(&ld, "app", colors)
	defer icon_result_free(&ld, &app)
	testing.expect(t, app.found && !app.mask && !app.recolored, "a full-colour SVG keeps its colours")
	testing.expect_value(t, theme_icon_test_px(app, 8, 8), [4]int{255, 0, 0, 255})

	signal := resolve(&ld, "signal-symbolic", colors)
	defer icon_result_free(&ld, &signal)
	testing.expect(t, signal.found && signal.mask && signal.recolored, "a symbolic SVG in the text colour is a mask")
	testing.expect_value(t, theme_icon_test_px(signal, 8, 8)[3], 255)

	badge := resolve(&ld, "badge-symbolic", colors)
	defer icon_result_free(&ld, &badge)
	testing.expect(t, badge.found && !badge.mask && badge.recolored, "a symbolic SVG with a status colour is rendered in its colours")
	testing.expectf(t, near(theme_icon_test_px(badge, 4, 8), {0x33, 0x66, 0x99, 255}), "the text half: %v", theme_icon_test_px(badge, 4, 8))
	testing.expectf(t, near(theme_icon_test_px(badge, 12, 8), {0xaa, 0, 0, 255}), "the error half: %v", theme_icon_test_px(badge, 12, 8))

	kde := resolve(&ld, "kde", colors)
	defer icon_result_free(&ld, &kde)
	testing.expect(t, kde.found && kde.mask, "a ColorScheme-Text icon is a mask too")

	pic := resolve(&ld, "pic", colors)
	defer icon_result_free(&ld, &pic)
	testing.expect(t, pic.found && !pic.mask, "a PNG keeps its colours")
	testing.expect_value(t, theme_icon_test_px(pic, 2, 8), [4]int{255, 0, 0, 255}) // 2 × 1 fitted to 16 × 8, centred
	testing.expect_value(t, theme_icon_test_px(pic, 13, 8), [4]int{0, 0, 255, 255})
	testing.expect_value(t, theme_icon_test_px(pic, 8, 1)[3], 0)

	tray := resolve(&ld, "tray-symbolic", colors)
	defer icon_result_free(&ld, &tray)
	testing.expect(t, tray.found && tray.mask, "a symbolic PNG is a mask")
	testing.expect_value(t, theme_icon_test_px(tray, 2, 8)[3], 255)

	old := resolve(&ld, "old", colors)
	defer icon_result_free(&ld, &old)
	testing.expect(t, old.found && !old.mask, "an XPM from pixmaps")
	testing.expect_value(t, theme_icon_test_px(old, 12, 8), [4]int{0, 0, 255, 255})

	missing := resolve(&ld, "no-such-thing", colors)
	defer icon_result_free(&ld, &missing)
	testing.expect(t, !missing.found, "a name nothing provides")
}

@(test)
theme_icons_load_and_follow_their_colour :: proc(t: ^testing.T) {
	root := theme_icon_test_tree(t, "view")
	defer os.remove_all(root)
	ui: Ui(Ov_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	te: Text_Engine
	if !text_engine_init(&te) do return
	defer text_engine_destroy(&te)
	tree_use_text_engine(&ui.tree, &te)
	theme_icon_test_search(&te.icon_loader, root)
	theme_icons_use(&te, "Test")
	view :: proc(ui: ^Ui(Ov_Msg), colour: Color) -> (app, signal, badge: Node) {
		begin_view(ui)
		row(ui, gap = .sm)
		app = theme_icon(ui, "app", size = 16)
		signal = theme_icon(ui, "signal-symbolic", size = 16, color = colour, label = "Signal strength")
		badge = theme_icon(ui, "badge-symbolic", size = 16, color = colour)
		end(ui)
		end_view(ui)
		frame(&ui.tree, {200, 40})
		return
	}
	glyphs :: proc(ui: ^Ui(Ov_Msg), cmds: ^[dynamic]gpu.Cmd) -> (n: int) {
		clear(cmds)
		render_prepare(&ui.tree, 1, nil, cmds)
		for c in cmds do if _, ok := c.(gpu.Glyph); ok do n += 1
		return
	}
	cmds := make([dynamic]gpu.Cmd, context.temp_allocator)

	app, signal, _ := view(&ui, rgb(0x336699))
	sd := node_get(&ui.tree, signal)
	testing.expect_value(t, sd.abs.w, 16)
	testing.expect_value(t, sd.access.role, Role.Image)
	testing.expect_value(t, sd.access.name, "Signal strength")
	testing.expect_value(t, node_get(&ui.tree, app).access.role, Role.None)
	testing.expect(t, lint(&ui.tree) == 0)

	testing.expect_value(t, glyphs(&ui, &cmds), 0) // nothing yet: the space is kept while they load
	testing.expect_value(t, len(te.icon_loader.requests), 3)
	testing.expect_value(t, glyphs(&ui, &cmds), 0)
	testing.expect_value(t, len(te.icon_loader.requests), 3) // asked once each
	theme_icons_load_now(&te)
	testing.expect(t, theme_icons_take(&te), "the icons arrived")
	testing.expect_value(t, glyphs(&ui, &cmds), 3)
	testing.expect_value(t, te.theme_icons["app\x00\x0016"].state, Theme_Icon_State.Colour)
	testing.expect_value(t, te.theme_icons["signal-symbolic\x00\x0016"].state, Theme_Icon_State.Mask)
	testing.expect_value(t, te.theme_icons["badge-symbolic\x00\x0016"].state, Theme_Icon_State.Recolour)

	// a new colour: the mask is tinted as drawn; only the badge renders again, its old colour drawn meanwhile
	view(&ui, rgb(0xcc8800))
	testing.expect_value(t, glyphs(&ui, &cmds), 3)
	testing.expect_value(t, len(te.icon_loader.requests), 1)
	theme_icons_load_now(&te)
	theme_icons_take(&te)
	testing.expect_value(t, glyphs(&ui, &cmds), 3)

	// another theme: everything loads again, from it, and what was there draws until it has
	testing.expect(t, theme_icons_use(&te, "Other"), "the theme changed")
	testing.expect_value(t, len(te.theme_icons), 0)
	testing.expect_value(t, glyphs(&ui, &cmds), 3)
	theme_icons_load_now(&te)
	theme_icons_take(&te)
	testing.expect_value(t, glyphs(&ui, &cmds), 1) // Other has only the app icon
	entry := te.theme_icons["app\x00\x0016"]
	testing.expect_value(t, entry.state, Theme_Icon_State.Colour)
	pages := atlas_pages(&te, .RGBA8)
	pg := pages[entry.slot.page_index]
	x := int(entry.slot.uv_rect[0] * f32(pg.width) + 0.5) + 8
	y := int(entry.slot.uv_rect[1] * f32(pg.height) + 0.5) + 8
	i := (y * int(pg.width) + x) * 4
	testing.expect_value(t, [4]u8{pg.pixels[i], pg.pixels[i + 1], pg.pixels[i + 2], pg.pixels[i + 3]}, [4]u8{0, 0, 255, 255})
}

// the theme icon inside `n` (itself included), NONE when there is none.
@(private = "file")
theme_icon_part :: proc(t: ^Tree, n: Node) -> Node {
	d := node_get(t, n)
	if d == nil do return NODE_NONE
	if ck, ok := d.kind.(Custom_Kind); ok && ck.paint == paint_theme_icon do return n
	for c := d.first; c != NODE_NONE; c = node_get(t, c).next do if f := theme_icon_part(t, c); f != NODE_NONE do return f
	return NODE_NONE
}

// the node under `n` with an accessibility role and `name`.
@(private = "file")
theme_icon_named :: proc(t: ^Tree, n: Node, name: string) -> Node {
	d := node_get(t, n)
	if d == nil do return NODE_NONE
	if d.access.role != .None && d.access.name == name do return n
	for c := d.first; c != NODE_NONE; c = node_get(t, c).next do if f := theme_icon_named(t, c, name); f != NODE_NONE do return f
	return NODE_NONE
}

// the glyph drawn inside `r`.
@(private = "file")
theme_icon_glyph_in :: proc(cmds: []gpu.Cmd, r: Rect) -> (gpu.Glyph, bool) {
	for c in cmds {
		g, ok := c.(gpu.Glyph)
		if ok && g.rect[0] >= r.x - 0.5 && g.rect[1] >= r.y - 0.5 && g.rect[0] + g.rect[2] <= r.x + r.w + 0.5 && g.rect[1] + g.rect[3] <= r.y + r.h + 0.5 do return g, true
	}
	return {}, false
}

@(private = "file")
theme_icon_label :: proc(t: ^Tree, b: Node) -> Node {
	for c := node_get(t, b).first; c != NODE_NONE; c = node_get(t, c).next {
		if _, ok := node_get(t, c).kind.(Text_Kind); ok do return c
	}
	return NODE_NONE
}

// A theme icon sits in a button, a menu item and a submenu row where an icon
// goes: it loads like any theme icon, takes the control's text colour, and
// is part of the control, not a node of its own for assistive technology. A
// new icon theme shows in them too.
@(test)
theme_icons_in_buttons_and_menus :: proc(t: ^testing.T) {
	root := theme_icon_test_tree(t, "controls")
	defer os.remove_all(root)
	ui: Ui(Ov_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	te: Text_Engine
	if !text_engine_init(&te) do return
	defer text_engine_destroy(&te)
	tree_use_text_engine(&ui.tree, &te)
	theme_icon_test_search(&te.icon_loader, root)
	theme_icons_use(&te, "Test")
	set_viewport(&ui.tree, {400, 300})
	view :: proc(ui: ^Ui(Ov_Msg)) -> (signal, app: Node) {
		begin_view(ui)
		row(ui, gap = .sm, padding = .sm, align = .Center)
		signal = button(ui, "Signal", Ov_Msg{}, variant = .Ghost, theme_icon = "signal-symbolic")
		app = button(ui, "Files", Ov_Msg{}, theme_icon = "app", icon_only = true)
		end(ui)
		if context_menu(ui, true, Ov_Msg{}) {
			menu_item(ui, "Open", Ov_Msg{}, theme_icon = "signal-symbolic")
			submenu(ui, "Open with", theme_icon = "app")
			end(ui)
		}
		end_view(ui)
		frame(&ui.tree, {400, 300})
		return
	}
	view(&ui)
	ui_tick(&ui, 10_000) // the menu's opening fade is over
	signal, app := view(&ui)
	item := theme_icon_named(&ui.tree, ui.tree.overlay, "Open")
	sub := theme_icon_named(&ui.tree, ui.tree.overlay, "Open with")
	testing.expect(t, item != NODE_NONE && sub != NODE_NONE, "fixture: the menu's rows")
	controls := [4]Node{signal, app, item, sub}
	icons: [4]Node
	for c, i in controls {
		icons[i] = theme_icon_part(&ui.tree, c)
		if icons[i] == NODE_NONE {
			testing.expectf(t, false, "control %d shows its theme icon", i)
			return
		}
		id := node_get(&ui.tree, icons[i])
		testing.expect_value(t, id.abs.w, ICON_SIZE)
		testing.expect_value(t, id.access.role, Role.None) // the control carries the name
	}
	testing.expect_value(t, node_get(&ui.tree, signal).access.name, "Signal")
	testing.expect_value(t, node_get(&ui.tree, app).access.name, "Files")
	testing.expect_value(t, node_get(&ui.tree, sub).access.role, Role.Menu_Item)
	ad := node_get(&ui.tree, app)
	testing.expect(t, ad.abs.w == ad.abs.h, "an icon-only button stays square")
	testing.expect(t, lint(&ui.tree) == 0)

	cmds := make([dynamic]gpu.Cmd, context.temp_allocator)
	render_prepare(&ui.tree, 1, nil, &cmds)
	testing.expect_value(t, len(te.icon_loader.requests), 2) // each name asked for once, wherever it shows
	theme_icons_load_now(&te)
	testing.expect(t, theme_icons_take(&te), "the icons arrived")
	clear(&cmds)
	render_prepare(&ui.tree, 1, nil, &cmds)
	for ic, i in icons {
		_, drawn := theme_icon_glyph_in(cmds[:], node_get(&ui.tree, ic).abs)
		testing.expectf(t, drawn, "control %d's icon is drawn in it", i)
	}
	g, _ := theme_icon_glyph_in(cmds[:], node_get(&ui.tree, icons[0]).abs)
	testing.expect_value(t, g.color, ui.tree.theme.color.primary) // a symbolic icon in the Ghost button's text colour
	g, _ = theme_icon_glyph_in(cmds[:], node_get(&ui.tree, icons[2]).abs)
	testing.expect_value(t, g.color, ui.tree.theme.color.on_surface) // and in the menu's

	testing.expect(t, theme_icons_use(&te, "Other"), "another icon theme")
	clear(&cmds)
	render_prepare(&ui.tree, 1, nil, &cmds)
	theme_icons_load_now(&te)
	theme_icons_take(&te)
	clear(&cmds)
	render_prepare(&ui.tree, 1, nil, &cmds)
	_, app_drawn := theme_icon_glyph_in(cmds[:], node_get(&ui.tree, icons[1]).abs)
	_, signal_drawn := theme_icon_glyph_in(cmds[:], node_get(&ui.tree, icons[0]).abs)
	testing.expect(t, app_drawn && !signal_drawn, "the new theme's icons show, without a restart (Other has no signal icon)")
}

// button_options: a capped button stops at its width and ends its label in
// "…", a tight row shortens it further, and the whole label stays its name
// and shows on hover; its icon takes the size and colour given, a full-colour
// one fading with the alpha. The settings apply in the build that sets them
// and stay until changed.
@(test)
button_options_cap_the_label_and_style_the_icon :: proc(t: ^testing.T) {
	root := theme_icon_test_tree(t, "options")
	defer os.remove_all(root)
	ui: Ui(Ov_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	te: Text_Engine
	if !text_engine_init(&te) do return
	defer text_engine_destroy(&te)
	tree_use_text_engine(&ui.tree, &te)
	theme_icon_test_search(&te.icon_loader, root)
	theme_icons_use(&te, "Test")
	set_viewport(&ui.tree, {600, 200})
	LONG :: "Inbox (3) — someone@example.org — Mozilla Thunderbird"
	Look :: struct {
		room:       f32,
		set:        bool,
		max_width:  f32,
		icon_size:  f32,
		icon_color: Color,
	}
	view :: proc(ui: ^Ui(Ov_Msg), look: Look) -> Node {
		begin_view(ui)
		row(ui, width = look.room, align = .Center)
		b := button(ui, LONG, Ov_Msg{}, variant = .Ghost, theme_icon = "app")
		if look.set do button_options(ui, b, max_width = look.max_width, icon_size = look.icon_size, icon_color = look.icon_color)
		end(ui)
		end_view(ui)
		frame(&ui.tree, {600, 200})
		return b
	}

	b := view(&ui, {room = 600})
	natural := node_get(&ui.tree, b).abs.w
	testing.expectf(t, natural > 200 && !text_trimmed(&ui.tree, theme_icon_label(&ui.tree, b)), "fixture: uncapped, the whole title shows (%v px)", natural)

	faded := Color{1, 1, 1, 0.5}
	b = view(&ui, {room = 600, set = true, max_width = 200, icon_size = 24, icon_color = faded})
	bd := node_get(&ui.tree, b)
	testing.expect_value(t, bd.abs.w, 200) // in the build that set it
	testing.expect(t, text_trimmed(&ui.tree, theme_icon_label(&ui.tree, b)), "the label ends in …")
	testing.expect_value(t, bd.access.name, LONG)
	ic := theme_icon_part(&ui.tree, b)
	testing.expect_value(t, node_get(&ui.tree, ic).abs.w, 24)
	cmds := make([dynamic]gpu.Cmd, context.temp_allocator)
	render_prepare(&ui.tree, 1, nil, &cmds)
	theme_icons_load_now(&te)
	theme_icons_take(&te)
	clear(&cmds)
	render_prepare(&ui.tree, 1, nil, &cmds)
	g, drawn := theme_icon_glyph_in(cmds[:], node_get(&ui.tree, ic).abs)
	testing.expect(t, drawn && g.color.a == 0.5, "a full-colour icon fades with the colour's alpha")

	b = view(&ui, {room = 120}) // not set again: the settings stay
	bd = node_get(&ui.tree, b)
	testing.expectf(t, bd.abs.w <= 120 && bd.abs.w > 24, "a tight row shortens it further, its icon kept: %v", bd.abs.w)
	b = view(&ui, {room = 600})
	testing.expect_value(t, node_get(&ui.tree, b).abs.w, 200)

	lbl := theme_icon_label(&ui.tree, b)
	ld := node_get(&ui.tree, lbl)
	ui_tick(&ui, 1000)
	pointer_move(&ui, {ld.abs.x + 5, ld.abs.y + 5})
	ui_tick(&ui, 1000)
	ui_tick(&ui, 1700)
	testing.expect_value(t, ui.tip_anchor, lbl)
	ui.needs_rebuild = false
	view(&ui, {room = 600})
	tip := node_first(&ui.tree, ui.tree.overlay)
	testing.expect_value(t, node_get(&ui.tree, tip).access.role, Role.Tooltip)
	if tip != NODE_NONE do testing.expect_value(t, node_get(&ui.tree, node_first(&ui.tree, tip)).kind.(Text_Kind).str, LONG) // the whole title on hover

	b = view(&ui, {room = 600, set = true}) // all back to their defaults
	testing.expect_value(t, node_get(&ui.tree, b).abs.w, natural)
	testing.expect(t, !text_trimmed(&ui.tree, theme_icon_label(&ui.tree, b)), "the whole title again")
	id := node_get(&ui.tree, theme_icon_part(&ui.tree, b))
	testing.expect_value(t, id.abs.w, ICON_SIZE)
	testing.expect_value(t, id.style.fg, ui.tree.theme.color.primary) // the label's colour again
	testing.expect_value(t, len(ui.button_opts), 0)
}

// A magnifying dock draws each icon at a run of sizes, and each size loads on
// its own. Until it has, the nearest size already loaded draws in its place,
// scaled; after the icon theme changes, the old picture draws until the new
// one arrives. Only an icon's first appearance draws nothing.

// one_icon: a view of the icon theme's `name` alone, `size` px, and its glyphs.
@(private = "file")
one_icon :: proc(ui: ^Ui(Ov_Msg), name: string, size: f32, fallback := Icon.None) {
	begin_view(ui)
	row(ui)
	theme_icon(ui, name, size = size, fallback = fallback)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {200, 200})
}

@(private = "file")
icon_glyphs :: proc(ui: ^Ui(Ov_Msg), cmds: ^[dynamic]gpu.Cmd) -> []gpu.Glyph {
	clear(cmds)
	render_prepare(&ui.tree, 1, nil, cmds)
	out := make([dynamic]gpu.Glyph, context.temp_allocator)
	for c in cmds do if g, ok := c.(gpu.Glyph); ok do append(&out, g)
	return out[:]
}

// texels_across: how many of its atlas page's texels a glyph samples across.
@(private = "file")
texels_across :: proc(te: ^Text_Engine, g: gpu.Glyph, format: runa.Atlas_Format) -> int {
	pages := atlas_pages(te, format)
	for p, i in pages do if te.pages[format][i].page == g.page do return int((g.uv[2] - g.uv[0]) * f32(p.width) + 0.5)
	return -1
}

@(test)
a_theme_icon_at_a_new_size_draws_a_loaded_size_meanwhile :: proc(t: ^testing.T) {
	root := theme_icon_test_tree(t, "stand-in")
	defer os.remove_all(root)
	ui: Ui(Ov_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	te: Text_Engine
	if !text_engine_init(&te) do return
	defer text_engine_destroy(&te)
	tree_use_text_engine(&ui.tree, &te)
	theme_icon_test_search(&te.icon_loader, root)
	theme_icons_use(&te, "Test")
	cmds := make([dynamic]gpu.Cmd, context.temp_allocator)

	for name, i in ([2]string{"app", "signal-symbolic"}) { // a full-colour icon and a mask
		format := runa.Atlas_Format.RGBA8 if i == 0 else .Alpha8
		one_icon(&ui, name, 16)
		testing.expectf(t, len(icon_glyphs(&ui, &cmds)) == 0, "%s: nothing on its first appearance", name)
		theme_icons_load_now(&te)
		theme_icons_take(&te)
		testing.expectf(t, len(icon_glyphs(&ui, &cmds)) == 1, "%s: drawn once loaded", name)

		one_icon(&ui, name, 40) // grown: 40 px has never loaded
		g := icon_glyphs(&ui, &cmds)
		testing.expectf(t, len(g) == 1, "%s: the 16 px picture draws while 40 px loads", name)
		if len(g) == 1 {
			testing.expectf(t, g[0].rect.z == 40 && g[0].rect.w == 40, "%s: scaled to its 40 px box (%v)", name, g[0].rect)
			testing.expectf(t, texels_across(&te, g[0], format) == 15, "%s: sampling the 16 px picture half a texel in (%d)", name, texels_across(&te, g[0], format))
		}
		theme_icons_load_now(&te)
		theme_icons_take(&te)
		g = icon_glyphs(&ui, &cmds)
		testing.expectf(t, len(g) == 1 && texels_across(&te, g[0], format) == 40, "%s: its own 40 px picture once it arrives", name)
	}
}

@(test)
a_stand_in_is_the_nearest_size_and_larger_first :: proc(t: ^testing.T) {
	testing.expect(t, theme_icon_nearer(48, 16, 32), "larger beats smaller")
	testing.expect(t, !theme_icon_nearer(16, 48, 32), "…whichever comes first")
	testing.expect(t, theme_icon_nearer(40, 48, 32), "of two larger, the nearer")
	testing.expect(t, theme_icon_nearer(24, 16, 32), "of two smaller, the nearer")
	testing.expect(t, theme_icon_nearer(32, 40, 32), "the size itself is the nearest")

	root := theme_icon_test_tree(t, "nearest")
	defer os.remove_all(root)
	ui: Ui(Ov_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	te: Text_Engine
	if !text_engine_init(&te) do return
	defer text_engine_destroy(&te)
	tree_use_text_engine(&ui.tree, &te)
	theme_icon_test_search(&te.icon_loader, root)
	theme_icons_use(&te, "Test")
	cmds := make([dynamic]gpu.Cmd, context.temp_allocator)
	for size in ([2]f32{16, 48}) {
		one_icon(&ui, "app", size)
		icon_glyphs(&ui, &cmds)
		theme_icons_load_now(&te)
		theme_icons_take(&te)
	}
	one_icon(&ui, "app", 32)
	g := icon_glyphs(&ui, &cmds)
	testing.expect(t, len(g) == 1 && texels_across(&te, g[0], .RGBA8) == 47, "the 48 px picture scaled down, not the 16 px one up")
}

@(test)
after_the_icon_theme_changes_the_old_picture_draws_until_the_new_one_arrives :: proc(t: ^testing.T) {
	root := theme_icon_test_tree(t, "theme-change")
	defer os.remove_all(root)
	ui: Ui(Ov_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	te: Text_Engine
	if !text_engine_init(&te) do return
	defer text_engine_destroy(&te)
	tree_use_text_engine(&ui.tree, &te)
	theme_icon_test_search(&te.icon_loader, root)
	theme_icons_use(&te, "Test")
	cmds := make([dynamic]gpu.Cmd, context.temp_allocator)

	one_icon(&ui, "app", 16)
	icon_glyphs(&ui, &cmds)
	theme_icons_load_now(&te)
	theme_icons_take(&te)
	red := icon_glyphs(&ui, &cmds)[0].uv

	testing.expect(t, theme_icons_use(&te, "Other"), "the theme changed") // a Light/Dark switch brings one
	g := icon_glyphs(&ui, &cmds)
	testing.expect(t, len(g) == 1 && g[0].uv == red, "Test's picture still draws while Other's loads")
	theme_icons_load_now(&te)
	theme_icons_take(&te)
	g = icon_glyphs(&ui, &cmds)
	testing.expect(t, len(g) == 1 && g[0].uv != red, "Other's picture once it arrives")
	testing.expect(t, "app\x00" not_in te.theme_icon_stale, "and Test's is let go")

	// a size never loaded in either theme, grown into just after the change: the new theme's picture stands in
	one_icon(&ui, "app", 24)
	g = icon_glyphs(&ui, &cmds)
	testing.expect(t, len(g) == 1 && texels_across(&te, g[0], .RGBA8) == 15, "Other's 16 px picture, scaled")
}

@(test)
an_icon_nothing_provides_keeps_its_fallback_at_a_new_size :: proc(t: ^testing.T) {
	root := theme_icon_test_tree(t, "missing-size")
	defer os.remove_all(root)
	ui: Ui(Ov_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	te: Text_Engine
	if !text_engine_init(&te) do return
	defer text_engine_destroy(&te)
	tree_use_text_engine(&ui.tree, &te)
	theme_icon_test_search(&te.icon_loader, root)
	theme_icons_use(&te, "Test")
	cmds := make([dynamic]gpu.Cmd, context.temp_allocator)

	one_icon(&ui, "no-such-thing", 16, fallback = .Check)
	icon_glyphs(&ui, &cmds)
	theme_icons_load_now(&te)
	theme_icons_take(&te)
	testing.expect(t, len(icon_glyphs(&ui, &cmds)) == 1, "its fallback once the lookup found nothing")
	one_icon(&ui, "no-such-thing", 40, fallback = .Check)
	testing.expect(t, len(icon_glyphs(&ui, &cmds)) == 1, "a new size goes straight to the fallback: no size will find it")
}

} // when ODIN_TEST