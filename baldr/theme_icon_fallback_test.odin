package baldr

@(require) import "core:fmt"
@(require) import "core:testing"
@(require) import "baldr:gpu"

// Test files are part of the package, so without this `when` every program
// that imports Baldr would type-check the whole suite too. ODIN_TEST is set
// by `odin test`; BALDR_TESTS lets ./build.sh check look inside.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// A theme icon nothing provides falls back instead of leaving a hole.


@(private = "file")
ThemeIconFallback_TMsg :: union { int }

@(private = "file")
parts_of :: proc(t: ^Tree, n: Node, p: Control_Part) -> (count: int, last: Node) {
	for c := node_get(t, n).first; c != NODE_NONE; c = node_get(t, c).next do if Control_Part(node_get(t, c).key) == p {
		count += 1
		last = c
	}
	return
}

// Given both `icon` and `theme_icon`, a button and a row draw the theme icon
// only, with the icon as the fallback it draws when no theme provides the name.
@(test)
controls_make_their_icon_the_theme_icons_fallback :: proc(t: ^testing.T) {
	ui: Ui(ThemeIconFallback_TMsg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	begin_view(&ui)
	column(&ui)
	b := button(&ui, "Terminal", ThemeIconFallback_TMsg(1), icon = .Terminal, theme_icon = "no-such-terminal")
	r := list_row(&ui, "Terminal", ThemeIconFallback_TMsg(2), icon = .Terminal, theme_icon = "no-such-terminal")
	tile := list_row(&ui, "Terminal", ThemeIconFallback_TMsg(3), icon = .Terminal, theme_icon = "no-such-terminal", variant = .Tile)
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {400, 300})
	tr := &ui.tree
	for n in ([]Node{b, r}) {
		icons, _ := parts_of(tr, n, .Icon)
		themed, ti := parts_of(tr, n, .Theme_Icon)
		testing.expect(t, icons == 0 && themed == 1, "the theme icon only, not both")
		testing.expect_value(t, tr.theme_icons[ti].fallback, Icon.Terminal)
	}
	_, box := parts_of(tr, tile, .Tile)
	_, ti := parts_of(tr, box, .Theme_Icon)
	testing.expect_value(t, tr.theme_icons[ti].fallback, Icon.Terminal)
	for c in draw_list(tr) do if v, ok := c.(Draw_Theme_Icon); ok do testing.expect_value(t, v.fallback, Icon.Terminal)
}

// While a theme icon's lookup runs, its place stays empty. Once it has found
// nothing, the icon draws its fallback there; one with no fallback asks for
// the theme's application-x-executable, and when that is missing too, draws
// Lucide's app window.
@(test)
a_theme_icon_nothing_provides_draws_its_fallback :: proc(t: ^testing.T) {
	ui: Ui(ThemeIconFallback_TMsg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	te: Text_Engine
	if !text_engine_init(&te) do return
	defer text_engine_destroy(&te)
	tree_use_text_engine(&ui.tree, &te)
	begin_view(&ui)
	row(&ui, gap = .sm)
	theme_icon(&ui, "no-such-app", size = 24, fallback = .Folder, key = 1)
	theme_icon(&ui, "no-such-tool", size = 24, key = 2)
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {300, 60})
	glyphs :: proc(tr: ^Tree) -> (n: int) {
		cmds := make([dynamic]gpu.Cmd, context.temp_allocator)
		render_prepare(tr, 1, nil, &cmds)
		for c in cmds do if _, ok := c.(gpu.Glyph); ok do n += 1
		return
	}
	key :: proc(name: string) -> string { return fmt.tprintf("%s\x00\x0024", name) }
	testing.expect_value(t, glyphs(&ui.tree), 0) // both still looking
	(&te.theme_icons[key("no-such-app")]).state = .Missing
	(&te.theme_icons[key("no-such-tool")]).state = .Missing
	testing.expect_value(t, glyphs(&ui.tree), 1) // the folder in the first's place; the second asks for the program icon
	_, asked := te.theme_icons[key(THEME_ICON_GENERIC)]
	testing.expect(t, asked, "the theme's program icon is looked up")
	testing.expect_value(t, len(te.icons), 1) // the folder, rasterised
	(&te.theme_icons[key(THEME_ICON_GENERIC)]).state = .Missing
	testing.expect_value(t, glyphs(&ui.tree), 2) // and the app window in the second's
	testing.expect_value(t, len(te.icons), 2)
}

} // when ODIN_TEST