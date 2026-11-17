package baldr

@(require) import "core:testing"
@(require) import "baldr:third_party/runa"

// Test files are part of the package, so without this `when` every program
// that imports Baldr would type-check the whole suite too. ODIN_TEST is set
// by `odin test`; BALDR_TESTS lets ./build.sh check look inside.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// Inter's figures are proportional, so a centred stopwatch reading "0:21.4"
// would change width ten times a second and shuffle sideways. `tabular` asks
// the face for figures of one width.

@(private = "file")
Figs_Msg :: enum { None }

@(private = "file")
tabfx_engine :: proc(t: ^testing.T, ui: ^Ui(Figs_Msg), te: ^Text_Engine) {
	if !text_engine_init(te) do testing.fail_now(t, "text_engine_init: embedded fonts failed to load")
	ui_init(ui)
	tree_use_text_engine(&ui.tree, te)
}

// The four bytes are the right four bytes. runa's `tag` returns 0 for a name
// that is not four bytes, and a feature a face lacks is a silent no-op, so a
// misspelt tag would shape nothing and say nothing about it.
@(test)
the_tabular_feature_is_the_one_runa_names :: proc(t: ^testing.T) {
	testing.expect_value(t, u32(tabular_figures[0].tag), 0x746E756D) // 'tnum'
	testing.expect_value(t, tabular_figures[0].value, 1)
	testing.expect_value(t, tabular_figures[0], runa.feature("tnum"))
	testing.expect_value(t, runa.feature("nope!").tag, runa.Feature_Setting{}.tag) // five bytes: no tag, no complaint
}

// The point of the whole thing: digits of different widths measure the
// same when they are asked to.
@(test)
tabular_figures_all_measure_the_same :: proc(t: ^testing.T) {
	ui: Ui(Figs_Msg)
	te: Text_Engine
	tabfx_engine(t, &ui, &te)
	defer { ui_destroy(&ui); text_engine_destroy(&te) }
	tr := &ui.tree

	// Inter's "1" is narrower than its "0"; if that ever stops being true the
	// test below means nothing.
	ones := tr.measure_text(tr, "111", 32, 0, .Regular, false, 0, false).x
	zeros := tr.measure_text(tr, "000", 32, 0, .Regular, false, 0, false).x
	testing.expect(t, ones != zeros, "proportional figures differ in width (if not, the face has changed)")

	tab_ones := tr.measure_text(tr, "111", 32, 0, .Regular, false, 0, true).x
	tab_zeros := tr.measure_text(tr, "000", 32, 0, .Regular, false, 0, true).x
	testing.expect_value(t, tab_ones, tab_zeros)
}

// A stopwatch, measured as it ticks: every tenth is the same width, so
// nothing centred on it moves.
@(test)
a_stopwatch_keeps_its_width_as_it_ticks :: proc(t: ^testing.T) {
	ui: Ui(Figs_Msg)
	te: Text_Engine
	tabfx_engine(t, &ui, &te)
	defer { ui_destroy(&ui); text_engine_destroy(&te) }
	tr := &ui.tree
	ticks := []string{"0:21.4", "0:21.5", "0:21.6", "0:21.7", "0:21.8", "0:21.9", "0:22.0", "0:22.1"}

	loose: f32
	tight: f32
	moved_loose, moved_tight := 0, 0
	for s, i in ticks {
		w := tr.measure_text(tr, s, 44, 0, .Regular, false, 0, false).x
		tw := tr.measure_text(tr, s, 44, 0, .Regular, false, 0, true).x
		if i > 0 {
			if w != loose do moved_loose += 1
			if tw != tight do moved_tight += 1
		}
		loose, tight = w, tw
	}
	testing.expect(t, moved_loose > 0, "proportional: the width changes as it ticks (the bug)")
	testing.expect_value(t, moved_tight, 0)
}

// The node's own width is what moved it, so that is what has to be still:
// a text node rebuilt with each tick keeps the width layout gave it.
@(test)
a_tabular_text_node_keeps_its_laid_out_width :: proc(t: ^testing.T) {
	ui: Ui(Figs_Msg)
	te: Text_Engine
	tabfx_engine(t, &ui, &te)
	defer { ui_destroy(&ui); text_engine_destroy(&te) }

	build :: proc(ui: ^Ui(Figs_Msg), s: string, tabular: bool) -> Rect {
		set_viewport(&ui.tree, {400, 200})
		begin_view(ui)
		column(ui, align = .Center, padding = .lg)
		n := text(ui, s, size = 44, tabular = tabular, key = 1)
		end(ui)
		end_view(ui)
		frame(&ui.tree, {400, 200})
		return node_get(&ui.tree, n).abs
	}

	a := build(&ui, "0:21.4", true)
	b := build(&ui, "0:11.1", true)
	testing.expect_value(t, a.w, b.w)
	testing.expect_value(t, a.x, b.x) // centred, so a still width means a still position

	c := build(&ui, "0:21.4", false)
	d := build(&ui, "0:11.1", false)
	testing.expect(t, c.w != d.w, "without it, the node itself is what changes width")
}

// A field's figures line up too: the drawn string's width is what the caret
// and the right edge are measured from, so a sum being typed must not
// shuffle either.
@(test)
a_field_can_line_its_figures_up :: proc(t: ^testing.T) {
	ui: Ui(Figs_Msg)
	te: Text_Engine
	tabfx_engine(t, &ui, &te)
	defer { ui_destroy(&ui); text_engine_destroy(&te) }

	caret_x_at :: proc(ui: ^Ui(Figs_Msg), v: ^Text, tabular: bool) -> f32 {
		set_viewport(&ui.tree, {400, 120})
		begin_view(ui)
		column(ui, padding = .sm)
		n := text_input(ui, v, label = "Sum", width = 240, tabular = tabular, key = 1)
		end(ui)
		end_view(ui)
		frame(&ui.tree, {400, 120})
		s := text_input_state(&ui.tree, n)
		text_input_set_selection(&ui.tree, n, len(str(v^)), len(str(v^)))
		return input_caret_x(&ui.tree, s, len(s.display)) // where the next character would go
	}

	ones: Text; text_set(&ones, "111"); defer text_destroy(&ones)
	zeros: Text; text_set(&zeros, "000"); defer text_destroy(&zeros)

	testing.expect(t, caret_x_at(&ui, &ones, false) != caret_x_at(&ui, &zeros, false), "proportional: the end moves with the digits")
	testing.expect_value(t, caret_x_at(&ui, &ones, true), caret_x_at(&ui, &zeros, true))
}

// The field measures a caret two ways: off the laid-out line when its
// glyph clusters are 1:1 with the characters (digits always are), and
// through `prefix_width` when a ligature or a composition has made them
// not. Both have to ask for the same figures, or a caret in a field that
// holds "1fi1" lands in a different place from one holding "0fi0".
@(test)
the_fallback_measurer_lines_its_figures_up_too :: proc(t: ^testing.T) {
	ui: Ui(Figs_Msg)
	te: Text_Engine
	tabfx_engine(t, &ui, &te)
	defer { ui_destroy(&ui); text_engine_destroy(&te) }

	loose := prefix_width(&te, "111", 32)
	tight := prefix_width(&te, "111", 32, tabular = true)
	testing.expect(t, loose != tight, "the fallback asks for the figures it was given")
	testing.expect_value(t, tight, prefix_width(&te, "000", 32, tabular = true))

	// …and the field reaches it: a decomposed "é" (e + U+0301) is composed
	// by GSUB, which is the case input_caret_x's own comment names as
	// leaving the clusters no longer 1:1.
	end_of :: proc(ui: ^Ui(Figs_Msg), v: ^Text, tabular: bool) -> f32 {
		set_viewport(&ui.tree, {400, 120})
		begin_view(ui)
		column(ui, padding = .sm)
		n := text_input(ui, v, label = "Sum", width = 240, tabular = tabular, key = 1)
		end(ui)
		end_view(ui)
		frame(&ui.tree, {400, 120})
		s := text_input_state(&ui.tree, n)
		return input_caret_x(&ui.tree, s, len(s.display) - 1) // inside the string, not its end
	}
	ones: Text; text_set(&ones, "1e\u03011"); defer text_destroy(&ones)
	zeros: Text; text_set(&zeros, "0e\u03010"); defer text_destroy(&zeros)
	testing.expect_value(t, end_of(&ui, &ones, true), end_of(&ui, &zeros, true))
}

// The two forms of the same string are different entries: a cache keyed
// without the flag would hand the second one the first one's lines.
@(test)
the_two_shapes_of_a_number_are_cached_apart :: proc(t: ^testing.T) {
	ui: Ui(Figs_Msg)
	te: Text_Engine
	tabfx_engine(t, &ui, &te)
	defer { ui_destroy(&ui); text_engine_destroy(&te) }
	tr := &ui.tree

	loose := tr.measure_text(tr, "11:11", 24, 0, .Regular, false, 0, false).x
	tight := tr.measure_text(tr, "11:11", 24, 0, .Regular, false, 0, true).x
	again := tr.measure_text(tr, "11:11", 24, 0, .Regular, false, 0, false).x
	testing.expect(t, loose != tight, "the same string, shaped two ways")
	testing.expect_value(t, again, loose) // …and asking again gives its own answer back
}

}
