package baldr

@(require) import "core:fmt"
@(require) import "core:os"
@(require) import "core:testing"
@(require) import "core:time"

// Test files are part of the package, so without this `when` every program
// that imports Baldr would type-check the whole suite too. ODIN_TEST is set
// by `odin test`; BALDR_TESTS lets ./build.sh check look inside.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// The family the theme's text is set in, chosen while the app runs: named
// once, every label, field, menu and tooltip follows, with the embedded
// faces behind it for whatever it lacks, and no error for a family this
// machine has not got.
//
// The toolkit's own two fonts stand in for families a machine has: real
// variable TrueType files, already in the binary, and plainly different.
// The code face stands in for a chosen UI family and the UI face for a
// chosen code family, so no test can pass by drawing what it would anyway.

@(private = "file")
Tf_Msg :: union { int }

@(private = "file")
PROBE :: "Probe Face" // the embedded monospace, named as a family

@(private = "file")
PROSE :: "Probe Prose" // …and the embedded UI face, for the code family

@(private = "file")
probe_engine :: proc(t: ^testing.T, te: ^Text_Engine) -> (probe, prose: Family_Id) {
	if !text_engine_init(te) do testing.fail_now(t, "text_engine_init")
	probe = text_family_bytes(te, PROBE, FONT_FILES[.Mono])
	prose = text_family_bytes(te, PROSE, FONT_FILES[.UI])
	if probe == 0 || prose == 0 do testing.fail_now(t, "the stand-in families did not load")
	return
}

@(private = "file")
line_width :: proc(te: ^Text_Engine, s: string, size: f32, mono := false, family: Family_Id = 0) -> f32 {
	lines := text_lines(te, s, size, 0, .Regular, mono, family = family)
	return lines[0].width if len(lines) > 0 else 0
}

@(private = "file")
scratch_dir :: proc(t: ^testing.T, name: string) -> string {
	base, err := os.temp_directory(context.temp_allocator)
	if err != nil do testing.fail_now(t, "no temp directory")
	dir := fmt.tprintf("%s/baldr-%s-%d", base, name, time.to_unix_nanoseconds(time.now()))
	os.make_directory_all(dir)
	return dir
}

// A font file on disk for the index to point at, and an index of one
// family holding it. The strings are cloned because font_index_destroy
// frees them.
@(private = "file")
write_font :: proc(t: ^testing.T, dir: string, data: []u8) -> string {
	path := fmt.tprintf("%s/probe.ttf", dir)
	if os.write_entire_file_from_bytes(path, data) != nil do testing.fail_now(t, "could not write the test font")
	return path
}

@(private = "file")
index_empty :: proc(te: ^Text_Engine) {
	te.font_index.allocator = context.allocator
	te.font_index.families = make(map[string][dynamic]Font_Face_File)
	te.font_index.names = make([dynamic]string)
}

@(private = "file")
index_add :: proc(te: ^Text_Engine, family, path: string, variable: bool) {
	files := make([dynamic]Font_Face_File)
	append(&files, Font_Face_File{
		path = clone_string(path), weight = 400, glyphs = 2000,
		variable = variable, weights = {100, 900} if variable else {400, 400},
	})
	te.font_index.families[clone_string(family)] = files
}

// What Family_Id 0 means: the family the theme names, where it names one.
// Its metrics *and* its advances: a taller face must get taller rows rather
// than clipped ones, so the line height comes from the family.
@(test)
the_themes_family_is_what_the_toolkit_draws :: proc(t: ^testing.T) {
	te: Text_Engine
	probe, _ := probe_engine(t, &te)
	defer text_engine_destroy(&te)

	embedded_lh := text_line_height(&te, 16)
	embedded_w := line_width(&te, "Appearance", 16)

	testing.expect(t, theme_families(&te, PROBE, ""), "the theme names it: what is drawn changed")
	testing.expect_value(t, te.ui_family, probe)
	testing.expect_value(t, text_line_height(&te, 16), text_line_height(&te, 16, family = probe))
	testing.expect(t, text_line_height(&te, 16) != embedded_lh, "its own line height, not the embedded face's")
	testing.expect_value(t, line_width(&te, "Appearance", 16), line_width(&te, "Appearance", 16, family = probe))
	testing.expect(t, line_width(&te, "Appearance", 16) != embedded_w, "and its own advances")
	testing.expect_value(t, text_ascent(&te, 16), text_ascent(&te, 16, family = probe))

	// The same theme installed again is not a change: tree_theme runs on
	// every preference and every glass report, and must not lay every
	// view out again each time.
	testing.expect(t, !theme_families(&te, PROBE, ""), "installed again: nothing changed")

	// And giving it up goes back to the face in the binary.
	testing.expect(t, theme_families(&te, "", ""), "a theme that names none is a change too")
	testing.expect_value(t, te.ui_family, Family_Id(0))
	testing.expect_value(t, text_line_height(&te, 16), embedded_lh)
	testing.expect_value(t, line_width(&te, "Appearance", 16), embedded_w)
}

// The code face is named apart from the prose one, and neither follows the
// other: a desktop may set its UI font without touching what an editor is
// set in.
@(test)
the_code_face_has_a_family_of_its_own :: proc(t: ^testing.T) {
	te: Text_Engine
	probe, prose := probe_engine(t, &te)
	defer text_engine_destroy(&te)

	ui_lh := text_line_height(&te, 16)
	mono_lh := text_line_height(&te, 16, mono = true)
	mono_w := line_width(&te, "fn main()", 14, mono = true)

	_ = theme_families(&te, "", PROSE) // only the code face
	testing.expect_value(t, te.ui_family, Family_Id(0))
	testing.expect_value(t, te.mono_family, prose)
	testing.expect_value(t, text_line_height(&te, 16), ui_lh) // prose is untouched
	testing.expect(t, text_line_height(&te, 16, mono = true) != mono_lh, "the code face follows it")
	testing.expect_value(t, text_line_height(&te, 16, mono = true), text_line_height(&te, 16, mono = true, family = prose))
	testing.expect(t, line_width(&te, "fn main()", 14, mono = true) != mono_w, "and is shaped in it")
	testing.expect(t, text_advance(&te, 14) != 0, "a cell still has a width")

	_ = theme_families(&te, PROBE, "") // …and only the prose one
	testing.expect_value(t, te.ui_family, probe)
	testing.expect_value(t, te.mono_family, Family_Id(0))
	testing.expect_value(t, text_line_height(&te, 16, mono = true), mono_lh)
	testing.expect_value(t, line_width(&te, "fn main()", 14, mono = true), mono_w)
}

// A family an app asked for outright still wins: a document in EB Garamond
// stays in EB Garamond whatever the theme is set in.
@(test)
a_family_the_app_asked_for_still_wins :: proc(t: ^testing.T) {
	te: Text_Engine
	_, prose := probe_engine(t, &te)
	defer text_engine_destroy(&te)
	asked := line_width(&te, "Appearance", 16, family = prose)

	_ = theme_families(&te, PROBE, "")
	testing.expect_value(t, line_width(&te, "Appearance", 16, family = prose), asked)
	testing.expect(t, line_width(&te, "Appearance", 16) != asked, "while the theme's text moved")
}

// A family this machine has not got draws as the embedded face: no error,
// no empty text, nothing for an app to handle. Apps hand over whatever
// their settings file says.
@(test)
a_family_this_machine_has_not_got_is_the_embedded_face :: proc(t: ^testing.T) {
	te: Text_Engine
	if !text_engine_init(&te) do testing.fail_now(t, "text_engine_init")
	defer text_engine_destroy(&te)
	index_empty(&te)
	te.font_index.built = true // a font list that is there and has nothing in it

	before := line_width(&te, "Appearance", 16)
	testing.expect(t, before > 0, "text measures to begin with")
	_ = theme_families(&te, "Nosuch Grotesk", "Nosuch Mono")
	testing.expect_value(t, te.ui_family, Family_Id(0))
	testing.expect_value(t, te.mono_family, Family_Id(0))
	testing.expect_value(t, line_width(&te, "Appearance", 16), before)
}

// A name given before the font list has been read is not wrong for the
// life of the app: the embedded face draws meanwhile, and the family is
// looked for again when the list arrives (fonts_arrived).
@(test)
a_family_named_before_the_font_list_arrives :: proc(t: ^testing.T) {
	te: Text_Engine
	if !text_engine_init(&te) do testing.fail_now(t, "text_engine_init")
	defer text_engine_destroy(&te)
	dir := scratch_dir(t, "themefont-late")
	defer os.remove_all(dir)
	path := write_font(t, dir, FONT_FILES[.Mono])

	index_empty(&te) // …and still being read: nothing is known to be missing
	te.font_scanner.wake = proc(user: rawptr) {}
	te.font_scanner.asked = true

	embedded := line_width(&te, "Appearance", 16)
	_ = theme_families(&te, "Probe Family", "")
	testing.expect_value(t, te.ui_family, Family_Id(0))
	testing.expect_value(t, line_width(&te, "Appearance", 16), embedded)

	index_add(&te, "Probe Family", path, variable = true)
	te.font_index.built = true
	fonts_arrived(&te) // what the run loop does when the worker hands one over
	testing.expect(t, te.ui_family != 0, "the family the theme named is found now")
	testing.expect(t, line_width(&te, "Appearance", 16) != embedded, "and the text is set in it")
	testing.expect_value(t, text_family_name(&te, te.ui_family), "Probe Family")
}

// The weights come from the family: a variable one is set to each of the
// three the type scale asks for, over one copy of its file.
@(test)
the_weights_come_from_the_family :: proc(t: ^testing.T) {
	te: Text_Engine
	if !text_engine_init(&te) do testing.fail_now(t, "text_engine_init")
	defer text_engine_destroy(&te)
	dir := scratch_dir(t, "themefont-var")
	defer os.remove_all(dir)
	index_empty(&te)
	index_add(&te, "Probe Family", write_font(t, dir, FONT_FILES[.UI]), variable = true)
	te.font_index.built = true

	id := text_family(&te, "Probe Family")
	e := family_of(&te, id)
	if e == nil || !e.ok do testing.fail_now(t, "the family did not load")
	testing.expect_value(t, len(e.blobs), 1) // one file, read once, every face over it
	for face in Family_Face do testing.expect(t, e.faces[face] != nil, "a face for every weight the type scale asks for")
	testing.expect(t, e.faces[.Regular] != e.faces[.Medium], "regular and medium are set apart")
	testing.expect(t, e.faces[.Medium] != e.faces[.Bold], "and medium and semibold")
	reg := prefix_width(&te, "mnemonic", 32, family = id)
	med := prefix_width(&te, "mnemonic", 32, weight = .Medium, family = id)
	bold := prefix_width(&te, "mnemonic", 32, weight = .Semibold, family = id)
	testing.expect(t, reg != med && med != bold, "…and each weight is shaped in its own instance")
}

// A family with one cut has it stand in for the weights it has not got —
// medium is its regular, semibold the nearest it has — and the file is
// loaded once, not once per weight.
@(test)
a_family_with_one_cut_stands_in_for_the_rest :: proc(t: ^testing.T) {
	te: Text_Engine
	if !text_engine_init(&te) do testing.fail_now(t, "text_engine_init")
	defer text_engine_destroy(&te)
	dir := scratch_dir(t, "themefont-static")
	defer os.remove_all(dir)
	index_empty(&te)
	index_add(&te, "Probe Family", write_font(t, dir, FONT_FILES[.UI]), variable = false)
	te.font_index.built = true

	id := text_family(&te, "Probe Family")
	e := family_of(&te, id)
	if e == nil || !e.ok do testing.fail_now(t, "the family did not load")
	testing.expect_value(t, len(e.blobs), 1)
	// `expect`, not `expect_value`: a failure would print two whole fonts.
	testing.expect(t, e.faces[.Medium] == e.faces[.Regular], "medium is its regular: nothing to set, so nothing to load twice")
	testing.expect(t, e.faces[.Bold] == e.faces[.Regular], "and semibold is the nearest it has")
	testing.expect(t, e.faces[.Italic] == nil, "and no slant is faked from an upright file")
	testing.expect_value(t, prefix_width(&te, "mnemonic", 32, weight = .Medium, family = id),
	                        prefix_width(&te, "mnemonic", 32, family = id))
}

// Live: a theme that names another family lays the text out again, as a
// text-size change does — no view rebuild needed, and no restart.
@(test)
the_themes_family_lays_the_text_out_again :: proc(t: ^testing.T) {
	ui: Ui(Tf_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	te: Text_Engine
	probe, _ := probe_engine(t, &te)
	defer text_engine_destroy(&te)
	tree_use_text_engine(&ui.tree, &te)

	view :: proc(ui: ^Ui(Tf_Msg)) -> (label, btn: Node) {
		begin_view(ui)
		column(ui, padding = .lg)
		label = text(ui, "Appearance", role = .Title)
		btn = button(ui, "Save", Tf_Msg(1))
		end(ui)
		end_view(ui)
		frame(&ui.tree, {600, 400})
		return
	}
	label, btn := view(&ui)
	// Heights, because a column stretches its children across it: what a
	// family changes about a label's box is how tall its line is.
	label_h := node_get(&ui.tree, label).rect.h
	btn_h := node_get(&ui.tree, btn).rect.h
	wide := text_measure(&ui.tree, "Appearance", 16, 0, .Regular).x
	testing.expect_value(t, ui_font_family(&ui.tree), "")
	testing.expect_value(t, mono_font_family(&ui.tree), "")

	th := ui.tree.theme_asked
	th.font_family = PROBE
	set_theme(&ui.tree, th)
	testing.expect(t, .Dirty_Layout in node_get(&ui.tree, label).flags, "the text is to be measured again")
	testing.expect_value(t, ui_font_family(&ui.tree), PROBE)

	label, btn = view(&ui)
	testing.expect(t, node_get(&ui.tree, label).rect.h != label_h, "a title's line is the family's height now")
	testing.expect(t, node_get(&ui.tree, btn).rect.h != btn_h, "and a button grows with its label")
	testing.expect(t, text_measure(&ui.tree, "Appearance", 16, 0, .Regular).x != wide, "…measured in it, through the tree")
	testing.expect_value(t, ui.tree.ui_family, probe)
}

// The family is the app's, not the window's: the surface that did not set
// the theme follows it too, which is what the run loop's call to
// tree_fonts_sync is for. Nothing else would tell that tree.
@(test)
every_surface_draws_in_the_same_family :: proc(t: ^testing.T) {
	te: Text_Engine
	probe, _ := probe_engine(t, &te)
	defer text_engine_destroy(&te)
	a, b: Tree
	tree_init(&a)
	defer tree_destroy(&a)
	tree_init(&b)
	defer tree_destroy(&b)
	tree_use_text_engine(&a, &te)
	tree_use_text_engine(&b, &te)

	th := a.theme_asked
	th.font_family = PROBE
	set_theme(&a, th)
	testing.expect_value(t, a.ui_family, probe)
	testing.expect(t, tree_fonts_sync(&b), "the other surface hears of it")
	testing.expect_value(t, b.ui_family, probe)
	testing.expect(t, !tree_fonts_sync(&b), "and only the once")
}

} // when ODIN_TEST
