package baldr

@(require) import "core:strings"
@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too; behind this `when` an app does not pay for them.
// ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh check look
// inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// Completion from a source that answers later: the editor asks, the app
// answers when it can, and what shows meanwhile is the last answer narrowed
// to what has been typed. And Ctrl+click on a word in a code editor.

@(private = "file")
Cl_Msg :: union { Complete_Ask, Pos }

@(private = "file")
Cl_App :: struct {
	doc:   Document,
	gen:   u64,          // the answer the app holds, for this ask
	items: []Completion,
	words: bool,         // the editor hears Ctrl+click on a word
}

@(private = "file")
cl_view :: proc(ui: ^Ui(Cl_Msg), app: ^Cl_App) -> (ed, area: Node) {
	set_viewport(&ui.tree, {600, 400})
	begin_view(ui)
	column(ui, padding = .lg)
	on_word: Handler(Cl_Msg, Pos)
	if app.words do on_word = proc(e: Ev(Pos)) -> Cl_Msg { return e.value }
	ed = code_editor(ui, &app.doc, nil, on_word_click = on_word, label = "Source", height = 200, key = 1)
	editor_complete(ui, ed, on_ask = proc(e: Ev(Complete_Ask)) -> Cl_Msg {
		a := e.value
		a.prefix = strings.clone(a.prefix, context.temp_allocator)
		return a
	}, open_on = ".")
	if app.gen > 0 do editor_completions(ui, ed, app.gen, app.items)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {600, 400})
	area = ui.tree.area_of_frame[ed]
	return
}

// cl_asks takes the asks sent since the last call.
@(private = "file")
cl_asks :: proc(ui: ^Ui(Cl_Msg)) -> []Complete_Ask {
	out := make([dynamic]Complete_Ask, context.temp_allocator)
	for m in ui.msgs do if a, ok := m.(Complete_Ask); ok do append(&out, a)
	clear(&ui.msgs)
	return out[:]
}

@(private = "file")
cl_shown :: proc(t: ^Tree, area: Node) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	s := &t.areas[area]
	if !s.complete.open do return {}
	for it in s.complete.items do append(&out, it.label)
	return out[:]
}

@(private = "file")
cl_same :: proc(a: []string, b: ..string) -> bool {
	if len(a) != len(b) do return false
	for x, i in a do if x != b[i] do return false
	return true
}

@(test)
completion_can_answer_later :: proc(t: ^testing.T) {
	ui: Ui(Cl_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	app := Cl_App{doc = document_make("")}
	defer document_destroy(&app.doc)
	ed, area := cl_view(&ui, &app)
	set_focus(&ui.tree, ed, false)

	// `.` opens it at once, with nothing typed after it, and asks
	text_area_text(&ui, "s")
	text_area_text(&ui, ".")
	asks := cl_asks(&ui)
	testing.expect_value(t, len(asks), 1)
	if len(asks) != 1 do return
	first := asks[0]
	testing.expect(t, first.trigger == '.' && first.prefix == "" && first.from == Pos{0, 2} && first.caret == Pos{0, 2})
	testing.expect_value(t, len(cl_shown(&ui.tree, area)), 0) // nothing to show until the answer

	// the answer comes later, and opens the list
	app.gen, app.items = first.gen, []Completion{{label = "name"}, {label = "size"}, {label = "state"}}
	cl_view(&ui, &app)
	cl_view(&ui, &app)
	testing.expect(t, cl_same(cl_shown(&ui.tree, area), "name", "size", "state"), "the answer shows")

	// typing asks again, and meanwhile the last answer narrows to what is typed
	text_area_text(&ui, "s")
	cl_view(&ui, &app)
	asks = cl_asks(&ui)
	testing.expect(t, len(asks) == 1 && asks[0].prefix == "s" && asks[0].gen > first.gen && asks[0].from == first.from)
	second := asks[0]
	testing.expect(t, cl_same(cl_shown(&ui.tree, area), "size", "state"), "the old answer, narrowed while the new one is on its way")

	// a newer answer replaces it; an older one is not taken again
	app.gen, app.items = second.gen, []Completion{{label = "size"}, {label = "slots"}}
	cl_view(&ui, &app)
	cl_view(&ui, &app)
	testing.expect(t, cl_same(cl_shown(&ui.tree, area), "size", "slots"))
	app.gen, app.items = first.gen, []Completion{{label = "stale"}}
	cl_view(&ui, &app)
	testing.expect(t, cl_same(cl_shown(&ui.tree, area), "size", "slots"), "an answer older than what is shown is dropped")

	// Enter takes the pick, replacing what was typed after the `.`
	key_event(&ui, .Enter, true, {})
	testing.expect_value(t, document_text(&app.doc, context.temp_allocator), "s.size")
	testing.expect_value(t, len(cl_shown(&ui.tree, area)), 0)

	// an answer for a word the caret has left is not shown
	text_area_text(&ui, " ")
	text_area_text(&ui, "x")
	text_area_text(&ui, ".")
	asks = cl_asks(&ui)
	testing.expect(t, len(asks) == 1, "a new word asks again")
	app.gen, app.items = second.gen + 0, []Completion{{label = "nope"}}
	cl_view(&ui, &app)
	cl_view(&ui, &app)
	testing.expect_value(t, len(cl_shown(&ui.tree, area)), 0)

	// an ask left unanswered for one word, answered once the caret is in
	// another, is not shown there
	key_event(&ui, .Escape, true, {})
	text_area_text(&ui, " ")
	text_area_text(&ui, "a")
	text_area_text(&ui, ".")
	left := cl_asks(&ui)
	text_area_text(&ui, " ")
	text_area_text(&ui, "b")
	text_area_text(&ui, ".")
	asks = cl_asks(&ui)
	testing.expect(t, len(left) == 1 && len(asks) == 1, "one ask for each word")
	if len(left) == 1 {
		app.gen, app.items = left[0].gen, []Completion{{label = "for_a"}}
		cl_view(&ui, &app)
		cl_view(&ui, &app)
		testing.expect_value(t, len(cl_shown(&ui.tree, area)), 0)
	}

	// Escape before the answer: it stays shut when the answer comes
	if len(asks) == 1 {
		key_event(&ui, .Escape, true, {})
		app.gen, app.items = asks[0].gen, []Completion{{label = "late"}}
		cl_view(&ui, &app)
		cl_view(&ui, &app)
		testing.expect_value(t, len(cl_shown(&ui.tree, area)), 0)
	}

	// Ctrl+Space asks too, saying so
	key_event(&ui, .Space, true, {.Ctrl})
	asks = cl_asks(&ui)
	testing.expect(t, len(asks) == 1 && asks[0].by_key, "Ctrl+Space asks")
	if len(asks) == 1 { // and an empty answer keeps it shut
		app.gen, app.items = asks[0].gen, {}
		cl_view(&ui, &app)
		testing.expect_value(t, len(cl_shown(&ui.tree, area)), 0)
	}
}

// The answer to what is typed now is shown as the app gave it; an older one,
// narrowed while a newer is on its way, puts what was typed first.
@(test)
a_narrowed_answer_puts_what_was_typed_first :: proc(t: ^testing.T) {
	ui: Ui(Cl_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	app := Cl_App{doc = document_make("")}
	defer document_destroy(&app.doc)
	ed, area := cl_view(&ui, &app)
	set_focus(&ui.tree, ed, false)
	for r in "fmt." do text_area_text(&ui, string([]u8{u8(r)}))
	asks := cl_asks(&ui) // "fm" and "fmt" asked too
	if !testing.expect(t, len(asks) > 0 && asks[len(asks) - 1].trigger == '.', "the `.` asks") do return
	app.gen, app.items = asks[len(asks) - 1].gen, []Completion{{label = "aprintfln"}, {label = "eprintln"}, {label = "println"}, {label = "sprint"}, {label = "for in"}}
	cl_view(&ui, &app)
	cl_view(&ui, &app)
	testing.expect(t, cl_same(cl_shown(&ui.tree, area), "aprintfln", "eprintln", "println", "sprint", "for in"), "as given, in its order, unfiltered")

	for r in "pri" do text_area_text(&ui, string([]u8{u8(r)}))
	cl_view(&ui, &app)
	asks = cl_asks(&ui)
	testing.expect(t, cl_same(cl_shown(&ui.tree, area), "println", "aprintfln", "eprintln", "sprint"), "narrowed: what starts with it first, then the answer's order")

	if len(asks) > 0 {
		app.gen, app.items = asks[len(asks) - 1].gen, []Completion{{label = "zeta"}, {label = "println"}}
		cl_view(&ui, &app)
		cl_view(&ui, &app)
		testing.expect(t, cl_same(cl_shown(&ui.tree, area), "zeta", "println"), "the answer for \"pri\" as given")
	}
}

// cl_caret is the editor's caret as drawn: one pixel wide and a line tall.
@(private = "file")
cl_caret :: proc(t: ^Tree) -> (r: Rect, ok: bool) {
	for c in draw_list(t) do if q, is := c.(Draw_Rect); is && q.rect.w == 1 && q.rect.h > 10 && q.rect.h < 40 do return q.rect, true
	return
}

@(test)
ctrl_click_on_a_word_tells_the_app :: proc(t: ^testing.T) {
	ui: Ui(Cl_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	app := Cl_App{doc = document_make("main :: proc() { run() }"), words = true}
	defer document_destroy(&app.doc)
	ed, area := cl_view(&ui, &app)
	set_focus(&ui.tree, ed, false)
	at := strings.index(document_text(&app.doc, context.temp_allocator), "run")
	st := &ui.tree.areas[area]
	st.caret, st.anchor = {0, at + 1}, {0, at + 1}
	area_touch(&ui.tree, area, st)
	cl_view(&ui, &app)
	c, shown := cl_caret(&ui.tree)
	testing.expect(t, shown, "the caret marks where the word is")
	on_word := [2]f32{c.x - 1, c.y + c.h * 0.5}
	end_of_line := [2]f32{node_get(&ui.tree, area).abs.x + node_get(&ui.tree, area).abs.w - 20, on_word.y}

	// held over the word: underlined, and the pointer a hand
	ui.pointer.mods = {.Ctrl}
	pointer_move(&ui, on_word)
	cl_view(&ui, &app)
	testing.expect(t, ui.tree.areas[area].word_hl.on && ui.tree.areas[area].word_hl.lo == at && ui.tree.areas[area].word_hl.hi == at + 3, "the word is marked")
	testing.expect_value(t, cursor_for(&ui), Cursor.Pointer)
	line := false
	for cmd in draw_list(&ui.tree) do if q, is := cmd.(Draw_Rect); is && q.rect.h == 1 && q.color == ui.tree.theme.color.accent_text do line = true
	testing.expect(t, line, "and underlined")

	// the click: the caret goes there, and the app hears where
	clear(&ui.msgs)
	pointer_button(&ui, .Left, true, on_word)
	pointer_button(&ui, .Left, false, on_word)
	testing.expect(t, len(ui.msgs) == 1, "the app hears it")
	if len(ui.msgs) == 1 {
		p, is_pos := ui.msgs[0].(Pos)
		testing.expect(t, is_pos && p.block == 0 && p.off >= at && p.off <= at + 3 && ui.tree.areas[area].caret == p, "at the word, with the caret there")
	}
	clear(&ui.msgs)

	// not on a word, or without Ctrl: a plain click
	ui.tree.now_ms += 1000
	pointer_button(&ui, .Left, true, end_of_line)
	pointer_button(&ui, .Left, false, end_of_line)
	testing.expect_value(t, len(ui.msgs), 0)
	ui.pointer.mods = {}
	pointer_move(&ui, on_word)
	testing.expect(t, !ui.tree.areas[area].word_hl.on, "letting go of Ctrl takes the line away")
	ui.tree.now_ms += 1000
	pointer_button(&ui, .Left, true, on_word)
	pointer_button(&ui, .Left, false, on_word)
	testing.expect_value(t, len(ui.msgs), 0)

	// an editor without the handler never offers it
	app.words = false
	cl_view(&ui, &app)
	ui.pointer.mods = {.Ctrl}
	pointer_move(&ui, on_word)
	testing.expect(t, !ui.tree.areas[area].word_hl.on, "no handler, no underline")
	ui.tree.now_ms += 1000
	pointer_button(&ui, .Left, true, on_word)
	pointer_button(&ui, .Left, false, on_word)
	testing.expect_value(t, len(ui.msgs), 0)
	ui.pointer.mods = {}
}

} // when ODIN_TEST
