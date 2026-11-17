package baldr

@(require) import "core:os"
@(require) import "core:strings"
@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: about 9 GB without this `when`, 1 GB with it.
// ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh check look
// inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// An editor shows its document in a family this machine has, at a size and
// line spacing the app chooses, and an app can list what there is.


@(private = "file")
Fx_Msg :: union { int }

@(private = "file")
Fx :: struct {
	ui: Ui(Fx_Msg),
	te: Text_Engine,
	doc: Document,
}

@(private = "file")
fx_start :: proc(fx: ^Fx, text := "The quick brown fox\njumps over it") -> bool {
	ui_init(&fx.ui)
	fx.doc = document_make(text)
	if !text_engine_init(&fx.te) do return false
	fx.ui.tree.text = &fx.te
	return true
}

@(private = "file")
fx_end :: proc(fx: ^Fx) {
	document_destroy(&fx.doc)
	text_engine_destroy(&fx.te)
	ui_destroy(&fx.ui)
}

@(private = "file")
fx_view :: proc(fx: ^Fx, font: Maybe(string) = nil, size: Maybe(f32) = nil, spacing: Maybe(f32) = nil, code := false) -> Node {
	ui := &fx.ui
	begin_view(ui)
	column(ui, padding = .lg)
	n := code_editor(ui, &fx.doc, nil, label = "Code", width = 420, height = 200) if code else text_area(ui, &fx.doc, label = "Notes", width = 420, height = 200)
	editor_options(ui, n, font = font, size = size, line_spacing = spacing)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {600, 600})
	return n
}

// a family this machine has, and one it does not
@(private = "file")
some_family :: proc(fx: ^Fx, fixed: bool) -> (string, bool) {
	list, _ := installed_fonts(&fx.ui.tree, context.temp_allocator)
	for f in list do if f.fixed == fixed do return f.family, true
	return "", false
}

@(test)
installed_fonts_lists_the_families_this_machine_has :: proc(t: ^testing.T) {
	fx: Fx
	if !fx_start(&fx) do return
	defer fx_end(&fx)
	list, scanned := installed_fonts(&fx.ui.tree, context.temp_allocator)
	testing.expect(t, scanned, "a tree with a text engine can scan")
	if len(list) == 0 {
		testing.expect(t, true, "no fonts installed here: nothing to check")
		return
	}
	sorted, fixed := true, 0
	for f, i in list {
		testing.expectf(t, len(f.family) > 0, "every family is named (%d)", i)
		if i > 0 && list[i - 1].family > f.family do sorted = false
		if f.fixed do fixed += 1
	}
	testing.expect(t, sorted, "sorted by name")
	testing.expect(t, fixed > 0, "some of them are fixed-width")
	again, _ := installed_fonts(&fx.ui.tree, context.temp_allocator)
	testing.expect_value(t, len(again), len(list)) // the scan is kept: asking again gives the same list
}

@(test)
a_font_file_says_what_family_and_face_it_is :: proc(t: ^testing.T) {
	// the toolkit's own files: read them as the scan reads a machine's
	files := [?]struct{ path, family: string } {
		{"assets/fonts/InterVariable.ttf", "Inter"},
		{"assets/fonts/JetBrainsMono-Variable.ttf", "JetBrains Mono"},
	}
	for f in files {
		path, family := f.path, f.family
		data, err := os.read_entire_file_from_path(path, context.temp_allocator)
		if err != nil {
			testing.expectf(t, true, "%s is not here: skipped", path)
			continue
		}
		face, ok := font_face_of(data)
		testing.expectf(t, ok, "%s reads as a font", path)
		testing.expectf(t, strings.has_prefix(face.family, family), "%s is %q, got %q", path, family, face.family)
		testing.expectf(t, face.file.variable, "%s has a wght axis", path)
		if strings.contains(path, "Mono") do testing.expect(t, face.file.fixed, "JetBrains Mono is fixed-width")
	}
	_, none := font_face_of({0, 1, 2, 3, 4, 5, 6, 7})
	testing.expect(t, !none, "rubbish is not a font")
	_, empty := font_face_of({})
	testing.expect(t, !empty, "nor is nothing")
}

@(test)
an_editor_shows_its_document_in_the_family_it_is_given :: proc(t: ^testing.T) {
	fx: Fx
	if !fx_start(&fx) do return
	defer fx_end(&fx)
	n := fx_view(&fx)
	area, s := editor_area(&fx.ui.tree, n)
	_ = area
	theme_width := span_x_disp(&fx.ui.tree, s, 0, block_spans(&fx.ui.tree, s, 0)[0], len(block_str(&fx.doc, 0)))
	name, ok := editor_font(&fx.ui.tree, n)
	testing.expect(t, name == "" && ok, "asked for nothing: the theme's font, and that is what it wanted")

	family, has := some_family(&fx, fixed = true) // a fixed-width family is the clearest change from the UI face
	if !has {
		testing.expect(t, true, "no fixed-width family installed: nothing to set")
		return
	}
	fx_view(&fx, font = family)
	testing.expect_value(t, s.family != 0, true)
	set_name, set_ok := editor_font(&fx.ui.tree, n)
	testing.expectf(t, set_ok && strings.equal_fold(set_name, family), "it draws in %q (%q, %v)", family, set_name, set_ok)
	wide := span_x_disp(&fx.ui.tree, s, 0, block_spans(&fx.ui.tree, s, 0)[0], len(block_str(&fx.doc, 0)))
	testing.expectf(t, wide != theme_width, "the line is laid out in the new family (%v, was %v)", wide, theme_width)

	// a family this machine does not have: the theme's font, and the app can tell
	fx_view(&fx, font = "Definitely Not Installed Sans")
	gone_name, gone_ok := editor_font(&fx.ui.tree, n)
	testing.expect(t, !gone_ok && gone_name == "", "a family that is not installed says so")
	back := span_x_disp(&fx.ui.tree, s, 0, block_spans(&fx.ui.tree, s, 0)[0], len(block_str(&fx.doc, 0)))
	testing.expect_value(t, back, theme_width) // …and draws as it did before

	fx_view(&fx, font = "") // back to the theme's own
	none_name, none_ok := editor_font(&fx.ui.tree, n)
	testing.expect(t, none_ok && none_name == "", "no family asked for")
}

@(test)
an_editors_size_and_line_spacing_are_the_apps_to_set :: proc(t: ^testing.T) {
	fx: Fx
	if !fx_start(&fx) do return
	defer fx_end(&fx)
	n := fx_view(&fx)
	_, s := editor_area(&fx.ui.tree, n)
	body := fx.ui.tree.theme.type.body.size
	testing.expect_value(t, s.size, body)
	single := area_line_h(&fx.ui.tree, s, 0)

	fx_view(&fx, size = body * 2)
	testing.expect_value(t, s.size, body * 2)
	bigger := area_line_h(&fx.ui.tree, s, 0)
	testing.expectf(t, bigger > single * 1.5, "twice the size is a much taller line (%v, was %v)", bigger, single)
	tall_doc := content_height(&fx.ui.tree, s)

	fx_view(&fx, size = body * 2, spacing = 1.5)
	spaced := area_line_h(&fx.ui.tree, s, 0)
	testing.expectf(t, abs(spaced - bigger * 1.5) < 0.01, "line spacing multiplies the line height (%v, %v)", spaced, bigger)
	testing.expect(t, content_height(&fx.ui.tree, s) > tall_doc, "…and the document is taller for it")

	// the caret and the view stay where they are through a change
	editor_select(&fx.ui, n, Pos{1, 4}, Pos{1, 6})
	fx_view(&fx, size = body, spacing = 1)
	lo, hi, ok := editor_selection(&fx.ui.tree, n)
	testing.expect(t, ok && lo == Pos{1, 4} && hi == Pos{1, 6}, "the selection is where it was")
	testing.expect_value(t, s.size, body)
	testing.expectf(t, abs(area_line_h(&fx.ui.tree, s, 0) - single) < 0.01, "and the line height is back (%v, %v)", area_line_h(&fx.ui.tree, s, 0), single)

	// nonsense is clamped rather than breaking the layout
	fx_view(&fx, spacing = 100)
	testing.expect(t, area_line_h(&fx.ui.tree, s, 0) <= single * 4 + 0.01, "a wild multiplier is clamped")
	fx_view(&fx, size = -10, spacing = 1)
	testing.expect_value(t, s.size, body) // a size of 0 or less is the theme's
}

@(test)
a_markdown_editor_is_laid_out_again_when_its_family_changes :: proc(t: ^testing.T) {
	fx: Fx
	if !fx_start(&fx, "Some prose to lay out\n\nand a second paragraph") do return
	defer fx_end(&fx)
	view :: proc(fx: ^Fx, font: Maybe(string) = nil) -> Node {
		ui := &fx.ui
		begin_view(ui)
		column(ui, padding = .lg)
		n := markdown_editor(ui, &fx.doc, label = "Notes", width = 420, height = 200)
		editor_options(ui, n, font = font)
		end(ui)
		end_view(ui)
		frame(&ui.tree, {600, 600})
		return n
	}
	n := view(&fx)
	_, s := editor_area(&fx.ui.tree, n)
	editor_select(&fx.ui, n, Pos{2, 0}, Pos{2, 0}) // the caret out of the first line, so it shows rendered
	view(&fx)
	before := area_rich(&fx.ui.tree, s, 0).cum[len(area_text(&fx.ui.tree, s, 0))]
	family, has := some_family(&fx, fixed = true)
	if !has do return
	view(&fx, font = family)
	after := area_rich(&fx.ui.tree, s, 0).cum[len(area_text(&fx.ui.tree, s, 0))]
	testing.expectf(t, after != before, "the rendered line is laid out in the new family (%v, was %v)", after, before)
	view(&fx, font = "")
	back := area_rich(&fx.ui.tree, s, 0).cum[len(area_text(&fx.ui.tree, s, 0))]
	testing.expect_value(t, back, before)

	// inline code keeps the code face: prose in another family, `code` in the mono one
	document_set_text(&fx.doc, "prose with `code` in it\n\nand more")
	view(&fx, font = family)
	editor_select(&fx.ui, n, Pos{2, 0}, Pos{2, 0})
	view(&fx, font = family)
	lay := area_rich(&fx.ui.tree, s, 0)
	code_run, prose_run := false, false
	for st in lay.styles {
		if .Code in st.attrs {
			code_run = true
			testing.expect(t, st.mono && st.family == 0, "an inline code run draws in the code face")
		} else if st.family != 0 {
			prose_run = true
		}
	}
	testing.expect(t, code_run && prose_run, "fixture: a code run beside prose in the family")
}

@(test)
a_code_editor_takes_a_family_too :: proc(t: ^testing.T) {
	fx: Fx
	if !fx_start(&fx, "x := 1\ny := 2") do return
	defer fx_end(&fx)
	n := fx_view(&fx, code = true)
	_, s := editor_area(&fx.ui.tree, n)
	cell := s.code.adv
	family, has := some_family(&fx, fixed = true)
	if !has do return
	fx_view(&fx, font = family, code = true)
	testing.expect(t, s.family != 0, "the code editor took the family")
	testing.expectf(t, s.code.adv != cell || cell == 0, "its cell width follows the family (%v, was %v)", s.code.adv, cell)
}

} // when ODIN_TEST