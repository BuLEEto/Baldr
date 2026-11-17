package baldr

@(require) import "core:strings"
@(require) import "core:testing"

// A selection in a styled paragraph can be copied. The press that starts it
// must give the paragraph the keyboard: `set_focus` on a node that is not
// focusable refuses silently, which would leave the keyboard in the chat's
// composer and send Ctrl+C there.
//
// These go through the real key path. Calling `styled_text_selected` off the
// state proves a selection would copy, not that the key reaches it.
when ODIN_TEST || #config(BALDR_TESTS, false) {

@(private = "file")
Sc_Msg :: union { string }

@(private = "file")
SC_TEXT :: "Meet me at the north gate at seven."

@(private = "file")
SC_RUNS := []Run{{end = 35}}

@(private = "file")
Sc_Clip :: struct { text: string }

@(private = "file")
sc_clip_install :: proc(ui: ^Ui(Sc_Msg), c: ^Sc_Clip) {
	ui.tree.clipboard = {
		user = c,
		set = proc(user: rawptr, text: string) -> bool {
			c := (^Sc_Clip)(user)
			delete(c.text)
			c.text = strings.clone(text)
			return true
		},
		get = proc(user: rawptr, allocator := context.allocator) -> (string, bool) {
			c := (^Sc_Clip)(user)
			if len(c.text) == 0 do return "", false
			return strings.clone(c.text, allocator), true
		},
	}
}

// A chat, as far as this needs one: a message above, then the composer — a
// field the app gives the keyboard when the chat opens — and a button either
// side so the Tab walk has somewhere to go.
@(private = "file")
sc_build :: proc(ui: ^Ui(Sc_Msg), draft: ^Text) -> (para, field, before, after: Node) {
	set_viewport(&ui.tree, {420, 320})
	begin_view(ui)
	column(ui, padding = .md, gap = .sm)
	before = button(ui, "Back", "back", key = 10)
	para = styled_text(ui, SC_TEXT, SC_RUNS, width = 380, key = 11)
	field = text_input(ui, draft, label = "Message", key = 12)
	after = button(ui, "Send", "send", key = 13)
	end(ui)
	end_view(ui)
	frame(&ui.tree, {420, 320})
	return
}

// The composer has the keyboard; a drag across part of a message, then
// Ctrl+C copies what was dragged.
@(test)
a_drag_in_a_paragraph_then_ctrl_c_copies_it :: proc(t: ^testing.T) {
	ui: Ui(Sc_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	clip: Sc_Clip
	defer delete(clip.text)
	sc_clip_install(&ui, &clip)
	draft: Text
	defer text_destroy(&draft)

	para, field, _, _ := sc_build(&ui, &draft)
	set_focus(&ui.tree, field, false) // what the app does when a chat opens
	testing.expect_value(t, ui.tree.focus, field)

	r := node_get(&ui.tree, para).abs
	y := r.y + r.h / 2
	pointer_button(&ui, .Left, true, {r.x + 2, y})
	pointer_move(&ui, {r.x + r.w * 0.5, y})
	pointer_button(&ui, .Left, false, {r.x + r.w * 0.5, y})
	sc_build(&ui, &draft)

	testing.expect_value(t, ui.tree.focus, para) // the press gave the paragraph the keyboard
	testing.expect(t, key_event(&ui, .C, true, {.Ctrl}), "Ctrl+C was taken")
	testing.expectf(t, len(clip.text) > 0, "the selection reached the clipboard (got %q)", clip.text)
	testing.expectf(t, strings.has_prefix(SC_TEXT, clip.text),
		"and it is the start of the message, as dragged (%q)", clip.text)
}

// A double click selects a word, and Ctrl+C copies that word.
@(test)
a_double_click_then_ctrl_c_copies_the_word :: proc(t: ^testing.T) {
	ui: Ui(Sc_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	clip: Sc_Clip
	defer delete(clip.text)
	sc_clip_install(&ui, &clip)
	draft: Text
	defer text_destroy(&draft)

	para, field, _, _ := sc_build(&ui, &draft)
	set_focus(&ui.tree, field, false)
	r := node_get(&ui.tree, para).abs
	at := [2]f32{r.x + 4, r.y + r.h / 2} // inside "Meet"
	// Through `mouse_button_event`, the run loop's own entry, 200 ms apart:
	// a press must be counted before it is acted on, or the paragraph reads
	// the previous press's count. Calling `pointer_button` straight skips
	// that ordering.
	mouse_button_event(&ui, .Left, true, at, 1000)
	mouse_button_event(&ui, .Left, false, at, 1010)
	mouse_button_event(&ui, .Left, true, at, 1200)
	mouse_button_event(&ui, .Left, false, at, 1210)
	sc_build(&ui, &draft)

	st := &ui.tree.styled[para]
	lo, hi := styled_sel(st)
	testing.expectf(t, hi > lo, "the double click selected the word (selection %d..%d)", lo, hi)
	testing.expect(t, key_event(&ui, .C, true, {.Ctrl}), "Ctrl+C was taken")
	testing.expect_value(t, clip.text, "Meet")
}

// Ctrl+A, once the paragraph has the keyboard, selects all of it — which is
// what the same key does in every other text that can be selected.
@(test)
ctrl_a_in_a_paragraph_selects_the_whole_message :: proc(t: ^testing.T) {
	ui: Ui(Sc_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	clip: Sc_Clip
	defer delete(clip.text)
	sc_clip_install(&ui, &clip)
	draft: Text
	defer text_destroy(&draft)

	para, _, _, _ := sc_build(&ui, &draft)
	r := node_get(&ui.tree, para).abs
	pointer_button(&ui, .Left, true, {r.x + 4, r.y + r.h / 2})
	pointer_button(&ui, .Left, false, {r.x + 4, r.y + r.h / 2})
	sc_build(&ui, &draft)

	testing.expect(t, key_event(&ui, .A, true, {.Ctrl}), "Ctrl+A was taken")
	testing.expect(t, key_event(&ui, .C, true, {.Ctrl}), "Ctrl+C was taken")
	testing.expect_value(t, clip.text, SC_TEXT)
}

// Not a Tab stop. A chat has a paragraph per message; Tab from the
// conversation to the composer must not walk through every one of them.
// The keyboard's way to a message's text is the message's own Copy.
@(test)
tab_passes_a_styled_paragraph_by :: proc(t: ^testing.T) {
	ui: Ui(Sc_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	draft: Text
	defer text_destroy(&draft)

	para, field, before, after := sc_build(&ui, &draft)
	set_focus(&ui.tree, before, true)
	key_event(&ui, .Tab, true, {})
	testing.expectf(t, ui.tree.focus == field,
		"Tab went from the button to the composer (focus is %v; the paragraph is %v)", ui.tree.focus, para)
	key_event(&ui, .Tab, true, {})
	testing.expect_value(t, ui.tree.focus, after)
	key_event(&ui, .Tab, true, {.Shift})
	key_event(&ui, .Tab, true, {.Shift})
	testing.expect_value(t, ui.tree.focus, before) // and backwards, passing it by again
}

}
