package baldr

@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: about 9 GB without this `when`, 1 GB with it.
// ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh check look
// inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

Fd_Msg :: struct { v: f32, c: Color }

@(private = "file")
on_fv :: proc(e: Ev(f32)) -> Fd_Msg { return {v = e.value} }
@(private = "file")
on_fc :: proc(e: Ev(Color)) -> Fd_Msg { return {c = e.value} }

// Every field that commits a value on Enter shows it the same way: focus
// stays and the text is selected, so typing again replaces it.
@(test)
enter_commits_and_selects_in_every_value_field :: proc(t: ^testing.T) {
	ui: Ui(Fd_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	set_viewport(&ui.tree, {600, 400})
	begin_view(&ui)
	column(&ui, padding = .lg, align = .Start)
	num := number_input(&ui, 3, on_fv, min = 0, max = 99, label = "Copies")
	pick := color_picker(&ui, rgb(0x3881f3), on_fc, label = "Accent")
	end(&ui)
	end_view(&ui)
	frame(&ui.tree, {600, 400})
	nf := ui.tree.spins[num].field
	set_focus(&ui.tree, nf, true)
	text_event(&ui, "4")
	key_event(&ui, .Enter, true, {})
	testing.expect(t, ui.tree.focus == nf, "Enter keeps focus in the field")
	lo, hi := text_input_selection(&ui.tree, nf)
	shown := string(ui.tree.spins[num].text.buf[:])
	testing.expect(t, lo == 0 && hi == len(shown) && hi > 0, "Enter selects the committed number")
	text_event(&ui, "7") // replaces the selection
	key_event(&ui, .Enter, true, {})
	testing.expect_value(t, ui.tree.spins[num].value, f32(7))
	hf := ui.tree.pickers[pick].field
	set_focus(&ui.tree, hf, true)
	key_event(&ui, .Enter, true, {})
	lo, hi = text_input_selection(&ui.tree, hf)
	hex := string(ui.tree.pickers[pick].hex.buf[:])
	testing.expect(t, lo == 0 && hi == len(hex) && hi > 0, "Enter selects the hex")
}

} // when ODIN_TEST