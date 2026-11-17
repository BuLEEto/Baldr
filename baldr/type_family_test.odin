package baldr

@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: they sit behind this `when` so an app does not pay
// for them (see canvas_test.odin).
when ODIN_TEST || #config(BALDR_TESTS, false) {

// A step of the type scale set in a family of its own — headings
// and controls' labels in a display face over body text in Inter — named
// once in the theme. And a family registered from one variable file has a
// real medium and bold, not its default instance for every weight.
//
// The embedded monospace stands in for the display face: a real font,
// already in the binary, and plainly not Inter, which is what these
// measure.

@(private = "file")
Tfm_Msg :: union { int }

@(private = "file")
DISPLAY_FACE :: "Probe Display"

@(private = "file")
family_width :: proc(ui: ^Ui(Tfm_Msg), s: string, role: Text_Role, family: Family_Id) -> f32 {
	st := text_style(&ui.tree.theme, role)
	return text_measure(&ui.tree, s, st.size, 0, st.weight, family = family).x
}

@(private = "file")
family_view :: proc(ui: ^Ui(Tfm_Msg)) -> (title, body, btn: Node) {
	begin_view(ui)
	column(ui, align = .Start)
	title = text(ui, "Appearance", role = .Title)
	body = text(ui, "Appearance")
	btn = button(ui, "Appearance", 1)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {600, 400})
	return
}

@(test)
a_step_of_the_type_scale_has_a_family_of_its_own :: proc(t: ^testing.T) {
	te: Text_Engine
	if !text_engine_init(&te) do testing.fail_now(t, "text_engine_init")
	defer text_engine_destroy(&te)
	display := text_family_bytes(&te, DISPLAY_FACE, FONT_FILES[.Mono])
	if display == 0 do testing.fail_now(t, "the stand-in family did not load")
	ui: Ui(Tfm_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	tree_use_text_engine(&ui.tree, &te)

	th := ui.tree.theme_asked
	th.type.title.family = DISPLAY_FACE
	th.type.label.family = DISPLAY_FACE
	set_theme(&ui.tree, th)
	testing.expect_value(t, te.role_family[.Title], display)
	testing.expect_value(t, te.role_family[.Label], display)
	testing.expect_value(t, te.role_family[.Body], Family_Id(0))

	title, body, btn := family_view(&ui)
	tw := node_get(&ui.tree, title).abs.w
	testing.expectf(t, abs(tw - family_width(&ui, "Appearance", .Title, display)) < 1, "the title is set in the display face: %v", tw)
	testing.expect(t, abs(tw - family_width(&ui, "Appearance", .Title, 0)) > 1, "…which is not Inter")
	bw := node_get(&ui.tree, body).abs.w
	testing.expectf(t, abs(bw - family_width(&ui, "Appearance", .Body, 0)) < 1, "body text stays in the theme's family: %v", bw)

	// A button's label is a Label text: it follows that step.
	lbl := node_first(&ui.tree, btn)
	lw := node_get(&ui.tree, lbl).abs.w
	testing.expectf(t, abs(lw - family_width(&ui, "Appearance", .Label, display)) < 1, "the button's label is in the display face: %v", lw)

	// And what is drawn is what was measured.
	title_size := ui.tree.theme.type.title.size
	drawn := false
	for c in draw_list(&ui.tree) {
		dt, ok := c.(Draw_Text)
		if ok && dt.str == "Appearance" && dt.size == title_size {
			testing.expect_value(t, family_now(&te, dt.family), display)
			drawn = true
		}
	}
	testing.expect(t, drawn, "the title was drawn")

	// Text in the code face stays in it: the step's family is for the
	// prose face.
	begin_view(&ui)
	own := text(&ui, "Appearance", role = .Title, mono = true)
	end_view(&ui)
	frame(&ui.tree, {600, 400})
	testing.expect_value(t, node_get(&ui.tree, own).kind.(Text_Kind).family, Family_Id(0))

	// Naming none puts the title back in the theme's face.
	th.type.title.family = ""
	set_theme(&ui.tree, th)
	testing.expect_value(t, te.role_family[.Title], Family_Id(0))
	title, _, _ = family_view(&ui)
	testing.expect(t, abs(node_get(&ui.tree, title).abs.w - family_width(&ui, "Appearance", .Title, 0)) < 1, "Inter again")
}

// A theme may name the family before the app has registered it — the
// theme is installed when the window is made, and the app's bytes may come
// after. The name is remembered as a family this machine has not got, and
// registering it then must fill that in, not hand back the empty one; the
// text already built is drawn in it without the view being built again.
@(test)
a_family_registered_after_the_theme_named_it :: proc(t: ^testing.T) {
	te: Text_Engine
	if !text_engine_init(&te) do testing.fail_now(t, "text_engine_init")
	defer text_engine_destroy(&te)
	te.font_index.allocator = context.allocator // an index read and empty: the name is not on this machine
	te.font_index.families = make(map[string][dynamic]Font_Face_File)
	te.font_index.names = make([dynamic]string)
	te.font_index.built = true
	ui: Ui(Tfm_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	tree_use_text_engine(&ui.tree, &te)

	th := ui.tree.theme_asked
	th.type.title.family = DISPLAY_FACE
	set_theme(&ui.tree, th)
	testing.expect_value(t, te.role_family[.Title], Family_Id(0)) // not found: drawn as the theme's own
	title, _, _ := family_view(&ui)
	testing.expect(t, abs(node_get(&ui.tree, title).abs.w - family_width(&ui, "Appearance", .Title, 0)) < 1, "Inter until it is registered")
	asked := text_family(&te, DISPLAY_FACE)
	testing.expect(t, !text_family_ok(&te, asked), "remembered as missing")

	id := text_family_bytes(&te, DISPLAY_FACE, FONT_FILES[.Mono])
	testing.expect_value(t, id, asked) // the id it was asked for under, now drawing
	testing.expect(t, text_family_ok(&te, id), "registered")
	testing.expect_value(t, te.role_family[.Title], id)

	testing.expect(t, tree_fonts_sync(&ui.tree), "the tree sees the family arrive") // what the run loop asks each time round
	frame(&ui.tree, {600, 400})
	testing.expectf(t, abs(node_get(&ui.tree, title).abs.w - family_width(&ui, "Appearance", .Title, id)) < 1,
		"the title already built is set in it: %v", node_get(&ui.tree, title).abs.w)
}

// One variable file is a whole family: each weight the type scale asks for
// is its own instance, set on its own axis, over one copy of the bytes —
// not the file's default instance at every weight, which would have no bold.
@(test)
a_variable_file_from_bytes_has_every_weight :: proc(t: ^testing.T) {
	te: Text_Engine
	if !text_engine_init(&te) do testing.fail_now(t, "text_engine_init")
	defer text_engine_destroy(&te)
	id := text_family_bytes(&te, "Probe Variable", FONT_FILES[.UI])
	e := family_of(&te, id)
	if e == nil || !e.ok do testing.fail_now(t, "the family did not load")
	testing.expect_value(t, len(e.blobs), 1)
	for face in Family_Face do testing.expect(t, e.faces[face] != nil, "a face for every weight")
	testing.expect(t, e.faces[.Regular] != e.faces[.Medium] && e.faces[.Medium] != e.faces[.Bold], "each its own instance")
	reg := prefix_width(&te, "mnemonic", 32, family = id)
	med := prefix_width(&te, "mnemonic", 32, weight = .Medium, family = id)
	bold := prefix_width(&te, "mnemonic", 32, weight = .Semibold, family = id)
	testing.expectf(t, reg < med && med < bold, "heavier is wider: %v %v %v", reg, med, bold)

	// A static file has nothing to set: its one cut stands in, as before.
	static := text_family_bytes(&te, "Probe Static", FONT_FILES[.Emoji])
	s := family_of(&te, static)
	if s == nil || !s.ok do testing.fail_now(t, "the static family did not load")
	testing.expect(t, s.faces[.Bold] == nil, "no bold made up from a static cut")
}

} // when ODIN_TEST
