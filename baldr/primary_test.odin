package baldr

@(require) import "core:strings"
@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: they sit behind this `when` so an app does not pay
// for them. ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh
// check look inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// The primary selection in text fields: what the person selects is given to
// it, what the app selects is not, a password never is, and a middle click
// types it where it lands.


@(private = "file")
Pr_Msg :: union { int }

@(private = "file")
Pr_Clip :: struct {
	sets: [dynamic]string,
	give: string,
}

@(private = "file")
pr_set :: proc(user: rawptr, text: string) -> bool {
	c := (^Pr_Clip)(user)
	append(&c.sets, strings.clone(text, context.temp_allocator))
	return true
}

@(private = "file")
pr_get :: proc(user: rawptr, allocator := context.allocator) -> (string, bool) {
	c := (^Pr_Clip)(user)
	return strings.clone(c.give, allocator), true
}

@(private = "file")
pr_view :: proc(ui: ^Ui(Pr_Msg), value: ^Text, doc: ^Document, password := false) -> (field, area: Node) {
	begin_view(ui)
	column(ui, align = .Start, padding = .lg, gap = .md)
	field = text_input(ui, value, label = "Name", width = 240, password = password)
	area = text_area(ui, doc, label = "Notes", width = 240, height = 100)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {400, 300})
	return
}

@(test)
a_selection_the_person_makes_is_the_primary_selection :: proc(t: ^testing.T) {
	te: Text_Engine
	if !text_engine_init(&te) do testing.fail_now(t, "text engine")
	defer text_engine_destroy(&te)
	ui: Ui(Pr_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	tree_use_text_engine(&ui.tree, &te)
	clip: Pr_Clip
	clip.sets = make([dynamic]string, context.temp_allocator)
	ui.tree.clipboard = {user = &clip, primary_get = pr_get, primary_set = pr_set}
	value := text_make("hello world")
	defer text_destroy(&value)
	doc := document_make("ab")
	defer document_destroy(&doc)
	field, area := pr_view(&ui, &value, &doc)

	fd := node_get(&ui.tree, field)
	at := [2]f32{fd.abs.x + 20, fd.abs.y + fd.abs.h / 2} // over "hello"
	for _ in 0 ..< 2 {
		pointer_button(&ui, .Left, true, at)
		pointer_button(&ui, .Left, false, at)
	}
	ui_after_events(&ui, 0)
	testing.expect_value(t, len(clip.sets), 1)
	if len(clip.sets) == 1 do testing.expect_value(t, clip.sets[0], "hello") // a double click: the word

	key_event(&ui, .A, true, {.Ctrl})
	ui_after_events(&ui, 0)
	testing.expect_value(t, len(clip.sets), 2)
	if len(clip.sets) == 2 do testing.expect_value(t, clip.sets[1], "hello world")

	key_event(&ui, .End, true, {})
	text_input_select_all(&ui.tree, field) // the app selecting: not the person
	ui_after_events(&ui, 0)
	testing.expect_value(t, len(clip.sets), 2)

	// a middle click in the notes types it where it lands
	clip.give = "one\ntwo "
	ad := node_get(&ui.tree, area)
	inner := input_inner(ad)
	pointer_button(&ui, .Middle, true, {inner.x + 1, inner.y + 2})
	pointer_button(&ui, .Middle, false, {inner.x + 1, inner.y + 2})
	testing.expect_value(t, document_text(&doc, context.temp_allocator), "one\ntwo ab")
	testing.expect_value(t, ui.tree.focus, area)
}

@(test)
a_password_never_gives_its_text_to_the_primary_selection :: proc(t: ^testing.T) {
	te: Text_Engine
	if !text_engine_init(&te) do testing.fail_now(t, "text engine")
	defer text_engine_destroy(&te)
	ui: Ui(Pr_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	tree_use_text_engine(&ui.tree, &te)
	clip: Pr_Clip
	clip.sets = make([dynamic]string, context.temp_allocator)
	ui.tree.clipboard = {user = &clip, primary_get = pr_get, primary_set = pr_set}
	value := text_make("secret")
	defer text_destroy(&value)
	doc := document_make("")
	defer document_destroy(&doc)
	field, _ := pr_view(&ui, &value, &doc, password = true)
	fd := node_get(&ui.tree, field)
	at := [2]f32{fd.abs.x + 20, fd.abs.y + fd.abs.h / 2}
	pointer_button(&ui, .Left, true, at)
	pointer_button(&ui, .Left, false, at)
	key_event(&ui, .A, true, {.Ctrl})
	ui_after_events(&ui, 0)
	testing.expect_value(t, len(clip.sets), 0)
}

} // when ODIN_TEST