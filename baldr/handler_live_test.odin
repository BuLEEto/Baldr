package baldr

@(require) import "core:testing"

// `on_x = msg if cond else nil` does not do what it reads like. Odin brings
// both arms of a ternary to one type, so the `nil` becomes a nil procedure
// inside the union rather than an empty union, and the handler compares
// unequal to nil though it can never send.
//
// Nothing fires and nothing crashes: `handler_send` already treats a nil
// proc as nothing. It shows where a widget asks "was I given one?" to decide
// whether to offer a control at all (an expand chevron, a Paste item, a
// claim on Enter) and is told yes. Every such question asks `handler_live`,
// which is public because an app holding a handler of its own needs it too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

@(private = "file")
Hl_Msg :: union { int, bool, string }

// hl_dead is what the ternary makes: the proc variant, holding nil. Written
// out rather than with `x if false else nil`, because a test that used the
// ternary would be testing the compiler's choice rather than this value.
@(private = "file")
hl_dead :: proc() -> Handler(Hl_Msg, bool) {
	p: proc(Ev(bool)) -> Hl_Msg
	return p // the variant is set; the proc inside it is nil
}

// The trap itself, stated so it cannot quietly change under us.
@(test)
a_handler_holding_a_nil_proc_is_not_nil_but_is_not_live :: proc(t: ^testing.T) {
	dead := hl_dead()
	testing.expect(t, dead != nil, "this is the trap: it compares unequal to nil")
	testing.expect(t, !handler_live(dead), "and handler_live is what sees through it")

	empty: Handler(Hl_Msg, bool) // what an app that passed nothing gives
	testing.expect(t, empty == nil && !handler_live(empty), "an unset handler is both")

	real: Handler(Hl_Msg, bool) = Hl_Msg(1)
	testing.expect(t, real != nil && handler_live(real), "a message handler is both")

	fn: Handler(Hl_Msg, bool) = proc(e: Ev(bool)) -> Hl_Msg { return Hl_Msg(e.value) }
	testing.expect(t, fn != nil && handler_live(fn), "and so is a real proc")
}

// The visible symptom: a chevron the reader can press that cannot do
// anything. `expandable` is decided by whether the row was given an
// `on_change`.
@(test)
a_row_given_a_dead_handler_is_not_expandable :: proc(t: ^testing.T) {
	ui: Ui(Hl_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	set_viewport(&ui.tree, {400, 300})

	begin_view(&ui)
	tree_view(&ui, flex = 1)
	n := ui.scopes[len(ui.scopes) - 1].node
	if tree_item(&ui, "src", Hl_Msg(1), on_change = hl_dead(), key = 1) do end(&ui)
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {400, 300})

	row := NODE_NONE
	for c := node_first(&ui.tree, n); c != NODE_NONE; c = node_next(&ui.tree, c) {
		if d := node_get(&ui.tree, c); d != nil && d.access.name == "src" do row = c
	}
	testing.expect(t, row != NODE_NONE, "the row is built")
	d := node_get(&ui.tree, row)
	// An expandable row says so to assistive technology; one that cannot
	// expand must not claim it, or the chevron is a promise nothing keeps.
	testing.expectf(t, d.access.states & {.Expanded, .Collapsed} == {},
		"a row with a dead on_change claims neither state (%v)", d.access.states)
}

// A markdown view handed a dead `on_link` registers nothing, so a link click
// is left to the app rather than going nowhere.
@(test)
a_markdown_view_given_a_dead_link_handler_registers_none :: proc(t: ^testing.T) {
	ui: Ui(Hl_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	set_viewport(&ui.tree, {400, 300})

	md: Markdown_Doc
	defer md_destroy(&md)
	md_set(&md, "[a link](https://example.com)\n")

	dead: proc(Ev(string)) -> Hl_Msg // the ternary's nil, written out
	begin_view(&ui)
	n := markdown_view(&ui, &md, width = 400)
	md_view_options(&ui, n, on_link = dead)
	end_view(&ui)
	testing.expect(t, !(n in ui.md_links), "a dead handler registers nothing")

	begin_view(&ui)
	n2 := markdown_view(&ui, &md, width = 400)
	md_view_options(&ui, n2, on_link = proc(e: Ev(string)) -> Hl_Msg { return Hl_Msg(e.value) })
	end_view(&ui)
	testing.expect(t, n2 in ui.md_links, "…and a real one still does")
}

}
