package baldr

@(require) import "core:testing"

when ODIN_TEST || #config(BALDR_TESTS, false) {

// A text size change re-lays out an open markdown view at the new size.
//
// `layout_node` skips a node whose constraints have not moved, so a theme
// change that dirtied only paint would leave every custom measure, and a
// finished reply's height, as they were. A type scale changes every size a
// widget asks for, so it invalidates measurement through
// `tree_fonts_changed`, as a font family change does.
//
// Two halves, both needed: the tree must re-measure, and `md_view_relayout`
// must not return early when it does. A test for either alone passes with
// the other missing.

@(private = "file")
Tsf_Msg :: union { int }

@(private = "file")
TSF_SRC :: "# A heading\n\nA paragraph long enough that it wraps at this width, so its height depends on the size it is set at.\n\n| part | qty |\n|---|---|\n| P001 | 130 |\n"

@(private = "file")
Tsf_Fx :: struct {
	te: Text_Engine,
	ui: Ui(Tsf_Msg),
	md: Markdown_Doc,
	n:  Node,
}

@(private = "file")
tsf_open :: proc(fx: ^Tsf_Fx, t: ^testing.T) {
	if !text_engine_init(&fx.te) do testing.fail_now(t, "text_engine_init: embedded fonts failed to load")
	ui_init(&fx.ui)
	fx.ui.tree.text = &fx.te
	md_set(&fx.md, TSF_SRC)
}

@(private = "file")
tsf_close :: proc(fx: ^Tsf_Fx) {
	ui_destroy(&fx.ui)
	md_destroy(&fx.md)
	text_engine_destroy(&fx.te)
}

@(private = "file")
tsf_build :: proc(fx: ^Tsf_Fx) -> ^Md_View_State {
	set_viewport(&fx.ui.tree, {700, 900})
	begin_view(&fx.ui)
	fx.n = markdown_view(&fx.ui, &fx.md, label = "Reply", width = 640)
	end_view(&fx.ui)
	frame(&fx.ui.tree, {700, 900})
	return &fx.ui.tree.md_views[fx.n]
}

@(test)
a_reply_follows_a_text_size_change :: proc(t: ^testing.T) {
	fx: Tsf_Fx
	tsf_open(&fx, t)
	defer tsf_close(&fx)

	s := tsf_build(&fx)
	if s == nil do testing.fail_now(t, "the view kept no state")
	before := s.content
	testing.expect(t, before > 0, "the reply has a height to begin with")

	set_text_scale(&fx.ui.tree, 1.5)
	s2 := tsf_build(&fx)
	testing.expectf(t, s2.content > before * 1.2,
		"a reply at 150%% text size is %.2f tall, where it was %.2f — it did not follow the change",
		s2.content, before)
	testing.expectf(t, s2.laid_size == fx.ui.tree.theme.type.body.size,
		"the blocks were laid out at %.3f while the theme's body size is %.3f",
		s2.laid_size, fx.ui.tree.theme.type.body.size)

	// …and back down again, so this is not "any change grows it"
	set_text_scale(&fx.ui.tree, 1)
	s3 := tsf_build(&fx)
	testing.expectf(t, abs(s3.content - before) < 0.5,
		"back at 100%% the reply is %.2f tall, where it started at %.2f", s3.content, before)
}

@(test)
a_type_scale_change_dirties_layout_not_only_paint :: proc(t: ^testing.T) {
	// The tree-level half, asserted on the mechanism: a *rebuilt* node
	// re-measures regardless, so watching a `text` node grow proves nothing.
	// A type-scale change must leave layout dirty, so a node whose
	// constraints have not moved and whose measure is cached is measured again.
	te: Text_Engine
	if !text_engine_init(&te) do testing.fail_now(t, "text_engine_init")
	defer text_engine_destroy(&te)
	ui: Ui(Tsf_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	ui.tree.text = &te

	set_viewport(&ui.tree, {400, 300})
	begin_view(&ui)
	column(&ui, padding = .none)
	n := text(&ui, "Some words that take a measurable amount of room")
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {400, 300})

	// laid out: the pass has cleared the flag
	testing.expect(t, .Dirty_Layout not_in node_get(&ui.tree, n).flags,
		"a node that has just been laid out is not still dirty")

	set_text_scale(&ui.tree, 1.5)
	testing.expect(t, .Dirty_Layout in node_get(&ui.tree, n).flags,
		"a type-scale change must leave layout dirty, not only paint")

	// A colour-only theme change must NOT cost a relayout of the whole tree.
	// Note `theme_asked`, not `theme`: tree_theme folds the text scale into
	// whatever it is handed, and `theme` has already had it folded in, so
	// passing that back would scale it twice and move the type scale after
	// all. set_text_scale passes `theme_asked` for the same reason.
	frame(&ui.tree, {400, 300})
	th := ui.tree.theme_asked
	th.color.primary = Color{1, 0, 0, 1}
	tree_theme(&ui.tree, th)
	testing.expect(t, .Dirty_Layout not_in node_get(&ui.tree, n).flags,
		"a theme change that leaves the type scale alone must not dirty layout")
}

}
