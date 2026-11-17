package baldr

@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: they sit behind this `when` so an app does not pay
// for them (see canvas_test.odin).
when ODIN_TEST || #config(BALDR_TESTS, false) {

// A caption set in the code face (a tool step under a reply, so the answer
// leads), and a wordmark set in a family the app ships because the machines
// it runs on will not have it.

@(private = "file")
Fb_Msg :: union { int }

// The toolkit's own mono font stands in for an app's bytes: it is a real
// TrueType file, already in the binary, and nothing else in the tree needs
// to ship a second one for a test.
@(private = "file")
SOME_FONT := FONT_FILES[.Mono]

@(test)
a_family_can_be_registered_from_bytes_the_app_carries :: proc(t: ^testing.T) {
	te: Text_Engine
	if !text_engine_init(&te) do testing.fail_now(t, "text_engine_init")
	defer text_engine_destroy(&te)

	id := text_family_bytes(&te, "Probe Face", SOME_FONT)
	testing.expect(t, id != 0, "the bytes loaded")
	testing.expect(t, text_family_ok(&te, id), "…and the family is usable")
	testing.expect_value(t, text_family_name(&te, id), "Probe Face")

	// Asking again by the same name is the same family, not a second load.
	testing.expect_value(t, text_family_bytes(&te, "Probe Face", SOME_FONT), id)
	testing.expect_value(t, text_family(&te, "Probe Face"), id) // and by name alone

	// It draws: a run of text in it has a width of its own.
	lines := text_lines(&te, "wordmark", 20, 0, .Regular, false, family = id)
	testing.expect(t, len(lines) > 0 && lines[0].width > 0, "it measures something")
}

// The bytes are copied, so an app may hand over a buffer it is about to
// free, or `#load`ed data that must never be freed with the family.
@(test)
family_bytes_are_copied_not_borrowed :: proc(t: ^testing.T) {
	te: Text_Engine
	if !text_engine_init(&te) do testing.fail_now(t, "text_engine_init")
	defer text_engine_destroy(&te)

	borrowed := make([]u8, len(SOME_FONT))
	copy(borrowed, SOME_FONT)
	id := text_family_bytes(&te, "Borrowed", borrowed)
	testing.expect(t, id != 0, "loaded from a buffer of the caller's")
	delete(borrowed) // the app's to free, right away

	testing.expect(t, text_family_ok(&te, id), "still usable after the caller freed its copy")
	after := text_lines(&te, "still here", 16, 0, .Regular, false, family = id)
	testing.expect(t, len(after) > 0 && after[0].width > 0, "and still measures")
}

// What is not a font comes back as 0 rather than as a broken family, so an
// app that does not check gets the theme's fonts instead of nothing. A
// .woff2 lands here too: unpacking one wants a Brotli decompressor, which
// the dependency rule does not allow.
@(test)
bytes_that_are_not_a_font_are_refused :: proc(t: ^testing.T) {
	te: Text_Engine
	if !text_engine_init(&te) do testing.fail_now(t, "text_engine_init")
	defer text_engine_destroy(&te)

	junk := []u8{'w', 'O', 'F', '2', 0, 1, 0, 0, 9, 9, 9, 9, 9, 9, 9, 9}
	testing.expect_value(t, text_family_bytes(&te, "Not A Font", junk), Family_Id(0))
	testing.expect_value(t, text_family_bytes(&te, "Nothing", nil), Family_Id(0))
	testing.expect_value(t, text_family_bytes(&te, "", SOME_FONT), Family_Id(0))
	testing.expect_value(t, text_family_bytes(nil, "No Engine", SOME_FONT), Family_Id(0))
}

// `text(…, mono = true)` sets a run in the code face, which measures
// differently from the UI face and reads as machinery beside the prose.
@(test)
a_text_can_be_set_in_the_mono_face :: proc(t: ^testing.T) {
	ui: Ui(Fb_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	te: Text_Engine
	if !text_engine_init(&te) do testing.fail_now(t, "text_engine_init")
	defer text_engine_destroy(&te)
	tree_use_text_engine(&ui.tree, &te)

	begin_view(&ui)
	column(&ui, padding = .md)
	prose := text(&ui, "run_command touch desk-test.txt", role = .Caption, key = 1)
	code := text(&ui, "run_command touch desk-test.txt", role = .Caption, mono = true, key = 2)
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {600, 300})

	pk, _ := node_get(&ui.tree, prose).kind.(Text_Kind)
	ck, _ := node_get(&ui.tree, code).kind.(Text_Kind)
	testing.expect(t, !pk.mono, "the first is the UI face")
	testing.expect(t, ck.mono, "…and the second the code face")

	// The box a column gives them is the same; what differs is the text, so
	// this asks the measurer, which must know about mono for layout to size
	// it at all.
	tr := &ui.tree
	ui_w := tr.measure_text(tr, pk.str, pk.size, 0, pk.weight, false, 0, false).x
	mono_w := tr.measure_text(tr, ck.str, ck.size, 0, ck.weight, true, 0, false).x
	testing.expect(t, ui_w > 0 && mono_w > 0, "both measure")
	testing.expectf(t, ui_w != mono_w, "the same words in two faces are not the same width: %v vs %v", ui_w, mono_w)

	// And paint says so, so the renderer draws it in that face.
	found := false
	for _, l in ui.tree.layers do for c in l.cmds {
		if v, ok := c.(Draw_Text); ok && v.mono do found = true
	}
	testing.expect(t, found, "the draw list asks for the code face")
}

// A family reaches the draw list the same way, so an app's wordmark is
// drawn in the face it shipped.
@(test)
a_text_can_be_set_in_a_family_the_app_carries :: proc(t: ^testing.T) {
	ui: Ui(Fb_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	te: Text_Engine
	if !text_engine_init(&te) do testing.fail_now(t, "text_engine_init")
	defer text_engine_destroy(&te)
	tree_use_text_engine(&ui.tree, &te)
	id := text_family_bytes(&te, "Wordmark", SOME_FONT)
	if id == 0 do testing.fail_now(t, "the probe font did not load")

	begin_view(&ui)
	column(&ui, padding = .md)
	n := text(&ui, "acme", size = 20, family = id, key = 1)
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {400, 200})

	k, _ := node_get(&ui.tree, n).kind.(Text_Kind)
	testing.expect_value(t, k.family, id)
	found := false
	for _, l in ui.tree.layers do for c in l.cmds {
		if v, ok := c.(Draw_Text); ok && v.family == id do found = true
	}
	testing.expect(t, found, "the draw list names the family")
}

}
