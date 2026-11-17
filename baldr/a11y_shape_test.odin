package baldr

// What each kind of object *is*, as a platform is told — the half that is
// not its name.
//
// macOS asks which of a class's methods a given element actually has
// (`isAccessibilitySelectorAllowed:`). Answer "all of them" and every
// element claims AXNumberOfCharacters, AXSelectedTextRange and
// AXVisibleCharacterRange, the marks of a text area, so a reader on a radio
// option tries to move by line instead of to the next option.
//
// The bridge answers from the model's own predicates, so these pin the
// predicates. All three bridges read them.

@(require) import "core:testing"

when ODIN_TEST || #config(BALDR_TESTS, false) {

@(private = "file")
Shape_Msg :: struct { i: int }

@(private = "file")
shape_of :: proc(ui: ^Ui(Shape_Msg), n: Node) -> (A11y_Obj, bool) {
	id, _ := a11y_id(0, n)
	return a11y_obj(id)
}

@(test)
a_radio_list_is_a_radio_group_of_radios :: proc(t: ^testing.T) {
	ui: Ui(Shape_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	begin_view(&ui)
	column(&ui, flex = 1)
	group := radio(&ui, 1, {"Apple", "Banana", "Cherry"}, label = "Favourite fruit")
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {400, 300})
	a11y_test_window(&ui.tree, "Fruit")
	defer a11y_test_reset()

	g, ok := shape_of(&ui, group)
	if !testing.expect(t, ok, "the group is exposed") do return
	// The set, not a box with a name: a reader steps between the options of
	// an AXRadioGroup, but treats a plain group's children as unrelated.
	testing.expect_value(t, g.role, A11y_Role.Radio_Group)
	testing.expect_value(t, g.name, "Favourite fruit")
	// A set of options is not text, has no quantity, and is not pressed.
	testing.expect(t, !g.has_text, "a radio group holds no text")
	testing.expect(t, !g.has_value, "…and no number a reader reads as a quantity")
	testing.expect(t, !g.has_action, "…and pressing the set itself means nothing")
}

@(test)
an_empty_field_is_still_a_text_object :: proc(t: ^testing.T) {
	ui: Ui(Shape_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	empty := text_make("")
	defer text_destroy(&empty)
	typed := text_make("hello")
	defer text_destroy(&typed)
	begin_view(&ui)
	column(&ui, flex = 1)
	a := text_input(&ui, &empty, label = "Search", key = 1)
	b := text_input(&ui, &typed, label = "Name", key = 2)
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {400, 300})
	a11y_test_window(&ui.tree, "Fields")
	defer a11y_test_reset()

	// Nothing typed yet is a true answer; having no text interface at all
	// is a lie about what the thing is, and makes an empty field answer
	// like a label.
	ea, ok := shape_of(&ui, a)
	if !testing.expect(t, ok, "the empty field is exposed") do return
	testing.expect(t, ea.has_text, "an empty field is still somewhere a reader may type")
	testing.expect(t, ea.editable, "…and still editable")

	eb, ok2 := shape_of(&ui, b)
	if !testing.expect(t, ok2, "the typed-in field is exposed") do return
	testing.expect(t, eb.has_text, "and so is one with something in it")
}

@(test)
a_label_is_a_name_and_not_a_body_of_text :: proc(t: ^testing.T) {
	ui: Ui(Shape_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	begin_view(&ui)
	column(&ui, flex = 1)
	lbl := text(&ui, "Favourite fruit")
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {400, 300})
	a11y_test_window(&ui.tree, "Label")
	defer a11y_test_reset()

	// The one place the contents and not the role decide: a static that
	// carries a *body* of text says so with value_text; a label never does,
	// so it stays a name, which is what a label is.
	l, ok := shape_of(&ui, lbl)
	if !testing.expect(t, ok, "the label is exposed") do return
	testing.expect(t, !l.has_text, "a label's text is its name, not a body to read line by line")
}

}
