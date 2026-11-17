package baldr

@(require) import "core:strings"
@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too; behind this `when` an app does not pay for them.
// ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh check look
// inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// An editor's context menu: a right-click or the Menu key says which
// Document position it landed on, for spelling suggestions, and the app's
// menu does Cut, Copy, Paste, Select All, Undo and Redo as the shortcuts
// do, greying what can't be done.


@(private = "file")
Ctx_Msg :: union { Editor_Context, int }

@(private = "file")
Ctx_Kind :: enum { Text, Code, Markdown }

@(private = "file")
on_ctx :: proc(e: Ev(Editor_Context)) -> Ctx_Msg { return e.value }

@(private = "file")
build :: proc(ui: ^Ui(Ctx_Msg), doc: ^Document, kind := Ctx_Kind.Text, menu := true, readonly := false, disabled := false, around := false) -> Node {
	begin_view(ui)
	column(ui, padding = .lg)
	if around {
		box := column(ui)
		context_area(ui, box, Ctx_Msg(7))
	}
	h: Handler(Ctx_Msg, Editor_Context)
	if menu do h = on_ctx
	n: Node
	switch kind {
	case .Text:     n = text_area(ui, doc, on_context = h, label = "Notes", width = 360, height = 200, disabled = disabled)
	case .Code:     n = code_editor(ui, doc, nil, on_context = h, label = "Code", width = 360, height = 200, disabled = disabled)
	case .Markdown: n = markdown_editor(ui, doc, on_context = h, label = "Notes", width = 360, height = 200, disabled = disabled)
	}
	editor_options(ui, n, readonly = readonly)
	if around do end(ui)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {500, 400})
	return n
}

// the window point `frac` of the way across the character that starts at `p`
// (0: its left edge, 1: its right edge), halfway down its line
@(private = "file")
point_at :: proc(t: ^Tree, n: Node, p: Pos, frac: f32) -> [2]f32 {
	area, s := editor_area(t, n)
	d := node_get(t, area)
	line, _, x := caret_line(t, s, p)
	x1 := x + 40 // past the end of the line
	if p.off < len(s.doc.blocks[p.block].text) {
		_, _, x1 = caret_line(t, s, pos_next_grapheme(s.doc, p))
	}
	inner := input_inner(d)
	scroll := scroll_offset(t, area)
	lh := area_line_h(t, s, p.block)
	return {inner.x + area_text_x(s) - scroll.x + block_indent(t, s, p.block) + x + (x1 - x) * frac,
		inner.y - scroll.y + block_text_top(t, s, p.block) + (f32(line) + 0.5) * lh}
}

@(private = "file")
right_click :: proc(ui: ^Ui(Ctx_Msg), at: [2]f32) -> (ctx: Editor_Context, sent: int) {
	clear(&ui.msgs)
	pointer_button(ui, .Right, true, at)
	pointer_button(ui, .Right, false, at)
	for m in ui.msgs {
		if c, ok := m.(Editor_Context); ok {
			ctx = c
			sent += 1
		}
	}
	return
}

@(private = "file")
Clip :: struct {
	text:    string,
	offered: []string, // what types reports
}

@(private = "file")
clip_install :: proc(ui: ^Ui(Ctx_Msg), c: ^Clip, with_types := false) {
	ui.tree.clipboard = {
		user = c,
		set = proc(user: rawptr, text: string) -> bool {
			c := (^Clip)(user)
			delete(c.text)
			c.text = strings.clone(text)
			return true
		},
		get = proc(user: rawptr, allocator := context.allocator) -> (string, bool) {
			c := (^Clip)(user)
			if len(c.text) == 0 do return "", false
			return strings.clone(c.text, allocator), true
		},
	}
	if with_types {
		ui.tree.clipboard.types = proc(user: rawptr, allocator := context.allocator) -> []string {
			return (^Clip)(user).offered
		}
	}
}

@(private = "file")
selection :: proc(t: ^Tree, n: Node) -> (lo, hi: Pos) {
	lo, hi, _ = editor_selection(t, n)
	return
}

@(test)
a_right_click_off_the_selection_moves_the_caret_there :: proc(t: ^testing.T) {
	ui: Ui(Ctx_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	doc := document_make("alpha beta gamma\nsecond line here")
	defer document_destroy(&doc)
	n := build(&ui, &doc)
	editor_select(&ui, n, Pos{0, 6}, Pos{0, 10}) // "beta"
	build(&ui, &doc)

	at := point_at(&ui.tree, n, Pos{1, 3}, 0.2) // on the "o" of "second"
	ctx, sent := right_click(&ui, at)
	testing.expect_value(t, sent, 1)
	testing.expect_value(t, ctx.pos, Pos{1, 3})
	testing.expect(t, !ctx.in_selection, "off the selection")
	testing.expect_value(t, ctx.at, at) // the menu opens under the pointer
	testing.expect_value(t, ui.context_pos, at)
	lo, hi := selection(&ui.tree, n)
	testing.expect(t, lo == Pos{1, 3} && hi == Pos{1, 3}, "the caret moved to the click, the selection went")
	area, _ := editor_area(&ui.tree, n)
	testing.expect_value(t, ui.tree.focus, area)

	// the right half of the space before "beta": its nearest caret stop is the selection's edge, but the space isn't selected
	editor_select(&ui, n, Pos{0, 6}, Pos{0, 10})
	ctx, sent = right_click(&ui, point_at(&ui.tree, n, Pos{0, 5}, 0.8))
	testing.expect(t, sent == 1 && ctx.pos == Pos{0, 6} && !ctx.in_selection, "beside the selection is off it")
	lo, hi = selection(&ui.tree, n)
	testing.expect(t, lo == hi, "and the caret moved")

	// past the end of a line where the selection stops
	editor_select(&ui, n, Pos{0, 6}, Pos{0, 16})
	ctx, _ = right_click(&ui, point_at(&ui.tree, n, Pos{0, 16}, 0.5))
	testing.expect(t, ctx.pos == Pos{0, 16} && !ctx.in_selection, "past the end of a line the selection ends on")
}

@(test)
a_right_click_on_the_selection_keeps_it :: proc(t: ^testing.T) {
	ui: Ui(Ctx_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	doc := document_make("alpha beta gamma\nsecond line here")
	defer document_destroy(&doc)
	n := build(&ui, &doc)

	cases := [?]struct { p: Pos, frac: f32, pos: Pos } {
		{{0, 6}, 0.2, {0, 6}},  // the left half of "b"
		{{0, 9}, 0.8, {0, 10}}, // the right half of the last "a": its nearest stop is the edge, the letter is selected
		{{0, 7}, 0.4, {0, 7}},  // inside
	}
	for c in cases {
		editor_select(&ui, n, Pos{0, 10}, Pos{0, 6}) // made backwards: the order doesn't matter
		ctx, sent := right_click(&ui, point_at(&ui.tree, n, c.p, c.frac))
		testing.expectf(t, sent == 1 && ctx.in_selection && ctx.pos == c.pos, "on %v: %v", c.p, ctx)
		lo, hi := selection(&ui.tree, n)
		testing.expectf(t, lo == Pos{0, 6} && hi == Pos{0, 10}, "the selection stays (%v)", c.p)
	}

	// past the end of a line the selection carries on from
	editor_select(&ui, n, Pos{0, 11}, Pos{1, 3})
	ctx, _ := right_click(&ui, point_at(&ui.tree, n, Pos{0, 16}, 0.5))
	testing.expect(t, ctx.in_selection && ctx.pos == Pos{0, 16}, "past the end of a selected line's text")
	lo, hi := selection(&ui.tree, n)
	testing.expect(t, lo == Pos{0, 11} && hi == Pos{1, 3}, "kept")
}

@(test)
the_menu_key_in_an_editor_asks_at_the_caret :: proc(t: ^testing.T) {
	ui: Ui(Ctx_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	doc := document_make("alpha beta gamma\nsecond line here")
	defer document_destroy(&doc)
	n := build(&ui, &doc)
	area, _ := editor_area(&ui.tree, n)
	set_focus(&ui.tree, area, true)
	editor_select(&ui, n, Pos{1, 7}, Pos{1, 7})

	clear(&ui.msgs)
	key_event(&ui, .Menu, true, {})
	testing.expect_value(t, len(ui.msgs), 1)
	ctx, _ := ui.msgs[0].(Editor_Context)
	testing.expect_value(t, ctx.pos, Pos{1, 7})
	testing.expect(t, !ctx.in_selection, "no selection")
	testing.expect_value(t, ui.context_pos, ctx.at)
	caret := point_at(&ui.tree, n, Pos{1, 7}, 0)
	_, s := editor_area(&ui.tree, n)
	testing.expectf(t, abs(ctx.at.x - caret.x) < 0.5, "at the caret's x (%v, caret %v)", ctx.at, caret)
	testing.expectf(t, abs(ctx.at.y - (caret.y + area_line_h(&ui.tree, s, 1) / 2)) < 0.5, "under its line (%v, caret %v)", ctx.at, caret)
	lo, hi := selection(&ui.tree, n)
	testing.expect(t, lo == Pos{1, 7} && hi == Pos{1, 7}, "nothing moved")

	editor_select(&ui, n, Pos{0, 6}, Pos{0, 10})
	clear(&ui.msgs)
	key_event(&ui, .F10, true, {.Shift})
	testing.expect_value(t, len(ui.msgs), 1)
	ctx, _ = ui.msgs[0].(Editor_Context)
	testing.expect(t, ctx.pos == Pos{0, 10} && ctx.in_selection, "Shift+F10, with a selection: at the caret, which is on it")
}

@(test)
an_editor_without_on_context_leaves_right_clicks_as_they_were :: proc(t: ^testing.T) {
	ui: Ui(Ctx_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	doc := document_make("alpha beta gamma")
	defer document_destroy(&doc)
	n := build(&ui, &doc, menu = false, around = true)
	editor_select(&ui, n, Pos{0, 2}, Pos{0, 2})
	at := point_at(&ui.tree, n, Pos{0, 12}, 0.5)
	clear(&ui.msgs)
	pointer_button(&ui, .Right, true, at)
	pointer_button(&ui, .Right, false, at)
	testing.expect_value(t, len(ui.msgs), 1)
	if len(ui.msgs) == 1 do testing.expect_value(t, ui.msgs[0], Ctx_Msg(7)) // the context_area around it
	lo, _ := selection(&ui.tree, n)
	testing.expect_value(t, lo, Pos{0, 2}) // the caret stayed

	build(&ui, &doc, menu = true, around = true) // given one, the editor's own comes first
	_, sent := right_click(&ui, at)
	testing.expect_value(t, sent, 1)
	testing.expect_value(t, len(ui.msgs), 1)

	build(&ui, &doc, menu = true, disabled = true, around = true)
	_, sent = right_click(&ui, at)
	testing.expect_value(t, sent, 0) // a disabled editor offers no menu
}

@(test)
editor_action_does_what_the_shortcuts_do :: proc(t: ^testing.T) {
	ui: Ui(Ctx_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	clip: Clip
	defer delete(clip.text)
	clip_install(&ui, &clip)
	by_key := document_make("alpha beta gamma\nsecond line here")
	defer document_destroy(&by_key)
	by_menu := document_make("alpha beta gamma\nsecond line here")
	defer document_destroy(&by_menu)
	view :: proc(ui: ^Ui(Ctx_Msg), a, b: ^Document) -> (ka, mb: Node) {
		begin_view(ui)
		column(ui)
		ka = text_area(ui, a, on_change = Ctx_Msg(1), label = "Keys", width = 360, height = 120)
		mb = text_area(ui, b, on_change = Ctx_Msg(2), label = "Menu", width = 360, height = 120)
		end(ui)
		end_view(ui)
		frame(&ui.tree, {500, 400})
		return
	}
	keys, menu := view(&ui, &by_key, &by_menu)
	area, _ := editor_area(&ui.tree, keys)
	set_focus(&ui.tree, area, false) // the menu's editor doesn't need focus
	same := proc(t: ^testing.T, ui: ^Ui(Ctx_Msg), keys, menu: Node, step: string) {
		_, a := editor_area(&ui.tree, keys)
		_, b := editor_area(&ui.tree, menu)
		ta := document_text(a.doc, context.temp_allocator)
		tb := document_text(b.doc, context.temp_allocator)
		testing.expectf(t, ta == tb, "%s: the same text (%q, %q)", step, ta, tb)
		testing.expectf(t, a.caret == b.caret && a.anchor == b.anchor, "%s: the same selection", step)
		testing.expectf(t, len(a.doc.undo) == len(b.doc.undo) && len(a.doc.redo) == len(b.doc.redo), "%s: the same undo steps", step)
	}
	Step :: struct { name: string, key: Key, mods: Mods, action: Editor_Action, clip: string, changes: bool }
	steps := [?]Step {
		{"copy", .C, {.Ctrl}, .Copy, "beta", false},
		{"cut", .X, {.Ctrl}, .Cut, "beta", true},
		{"undo", .Z, {.Ctrl}, .Undo, "beta", true},
		{"redo", .Z, {.Ctrl, .Shift}, .Redo, "beta", true},
		{"undo again", .Z, {.Ctrl}, .Undo, "beta", true},
		{"paste", .V, {.Ctrl}, .Paste, "beta", true},
		{"undo the paste", .Z, {.Ctrl}, .Undo, "beta", true},
		{"redo with Ctrl+Y", .Y, {.Ctrl}, .Redo, "beta", true},
		{"select all", .A, {.Ctrl}, .Select_All, "beta", false},
		{"cut it all", .X, {.Ctrl}, .Cut, "alpha beta gamma\nbetasecond line here", true},
		{"paste it back", .V, {.Ctrl}, .Paste, "alpha beta gamma\nbetasecond line here", true},
	}
	editor_select(&ui, keys, Pos{0, 6}, Pos{0, 10})
	editor_select(&ui, menu, Pos{0, 6}, Pos{0, 10})
	for st in steps {
		if st.name == "paste" { // somewhere else, so the paste has a place to go
			editor_select(&ui, keys, Pos{1, 0}, Pos{1, 0})
			editor_select(&ui, menu, Pos{1, 0}, Pos{1, 0})
		}
		clear(&ui.msgs)
		key_event(&ui, st.key, true, st.mods)
		did := editor_action(&ui, menu, st.action)
		testing.expectf(t, did, "%s: done", st.name)
		same(t, &ui, keys, menu, st.name)
		testing.expectf(t, clip.text == st.clip, "%s: the clipboard holds %q", st.name, clip.text)
		changed := 0
		for m in ui.msgs do if v, ok := m.(int); ok do changed |= v
		testing.expectf(t, changed == (3 if st.changes else 0), "%s: on_change from both (%d)", st.name, changed)
		keys, menu = view(&ui, &by_key, &by_menu)
	}
	testing.expect_value(t, ui.tree.focus, area) // editor_action left focus alone
}

@(test)
editor_actions_say_what_can_be_done :: proc(t: ^testing.T) {
	ui: Ui(Ctx_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	clip: Clip
	defer delete(clip.text)
	clip_install(&ui, &clip, with_types = true)
	doc := document_make("")
	defer document_destroy(&doc)
	n := build(&ui, &doc)
	testing.expect_value(t, editor_actions(&ui.tree, n), Editor_Actions{}) // empty, nothing on the clipboard
	testing.expect(t, !editor_action(&ui, n, .Select_All) && !editor_action(&ui, n, .Undo) && !editor_action(&ui, n, .Paste), "nothing to do")

	clip.text = strings.clone("an image")
	clip.offered = {"image/png"}
	testing.expect_value(t, editor_actions(&ui.tree, n), Editor_Actions{}) // no text on offer
	clip.offered = {"image/png", "text/plain;charset=utf-8"}
	testing.expect_value(t, editor_actions(&ui.tree, n), Editor_Actions{.Paste})

	document_set_text(&doc, "hello world")
	build(&ui, &doc)
	testing.expect_value(t, editor_actions(&ui.tree, n), Editor_Actions{.Paste, .Select_All})
	editor_select(&ui, n, Pos{0, 0}, Pos{0, 5})
	testing.expect_value(t, editor_actions(&ui.tree, n), Editor_Actions{.Cut, .Copy, .Paste, .Select_All})
	testing.expect(t, editor_action(&ui, n, .Cut), "cut")
	build(&ui, &doc)
	testing.expect_value(t, editor_actions(&ui.tree, n), Editor_Actions{.Paste, .Select_All, .Undo})
	testing.expect(t, editor_action(&ui, n, .Undo), "undo")
	build(&ui, &doc)
	testing.expect_value(t, editor_actions(&ui.tree, n), Editor_Actions{.Paste, .Select_All, .Redo})

	// readonly: reading and selecting only, from the menu and the keys alike
	build(&ui, &doc, readonly = true)
	editor_select(&ui, n, Pos{0, 0}, Pos{0, 5})
	testing.expect_value(t, editor_actions(&ui.tree, n), Editor_Actions{.Copy, .Select_All})
	before := document_text(&doc, context.temp_allocator)
	testing.expect(t, !editor_action(&ui, n, .Cut) && !editor_action(&ui, n, .Paste) && !editor_action(&ui, n, .Redo), "no edits")
	area, _ := editor_area(&ui.tree, n)
	set_focus(&ui.tree, area, false)
	key_event(&ui, .Y, true, {.Ctrl})
	key_event(&ui, .X, true, {.Ctrl})
	testing.expect_value(t, document_text(&doc, context.temp_allocator), before)
	testing.expect(t, editor_action(&ui, n, .Copy) && clip.text == "hello", "copying is allowed")

	build(&ui, &doc, disabled = true)
	testing.expect_value(t, editor_actions(&ui.tree, n), Editor_Actions{})
	testing.expect(t, !editor_action(&ui, n, .Copy), "a disabled editor does nothing")
	testing.expect_value(t, editor_actions(&ui.tree, 0), Editor_Actions{})
}

@(test)
code_and_markdown_editors_say_where_too :: proc(t: ^testing.T) {
	ui: Ui(Ctx_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)

	code := document_make("main :: proc() {\n\tfmt.println(\"hi\")\n}")
	defer document_destroy(&code)
	n := build(&ui, &code, kind = .Code)
	ctx, sent := right_click(&ui, point_at(&ui.tree, n, Pos{1, 5}, 0.3))
	testing.expect(t, sent == 1 && ctx.pos == Pos{1, 5}, "a code editor: the position past its gutter and tab")
	testing.expect(t, editor_action(&ui, n, .Select_All), "editor_action takes the frame a code editor returns")
	lo, hi := selection(&ui.tree, n)
	testing.expect(t, lo == Pos{} && hi == document_end(&code), "all of it")

	// a markdown line shows without its marks until the caret is in it: the position is in the source
	md := document_make("Some **bold** words\n\nother")
	defer document_destroy(&md)
	m := build(&ui, &md, kind = .Markdown)
	editor_select(&ui, m, Pos{2, 0}, Pos{2, 0})
	build(&ui, &md, kind = .Markdown)
	_, s := editor_area(&ui.tree, m)
	testing.expect_value(t, area_text(&ui.tree, s, 0), "Some bold words") // fixture: rendered
	ctx, sent = right_click(&ui, point_at(&ui.tree, m, Pos{0, 8}, 0.3)) // the "o" of "bold"
	testing.expect(t, sent == 1 && ctx.pos == Pos{0, 8} && !ctx.in_selection, "the source position of the letter clicked")
	lo, hi = selection(&ui.tree, m)
	testing.expect(t, lo == Pos{0, 8} && hi == Pos{0, 8}, "the caret is there")
}

} // when ODIN_TEST