package baldr

@(require) import "core:strings"
@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too: they sit behind this `when` so an app does not pay
// for them. ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh
// check look inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// A composer takes more than text: a paste that brings a picture or files
// and no text reaches the app as a Paste_Other, so it can attach it. A paste
// that brought text is untouched.


@(private = "file")
Po_Msg :: union { Paste_Other, string }

@(private = "file")
Po_Clip :: struct {
	text:    string,
	offered: []string,
}

@(private = "file")
po_install :: proc(ui: ^Ui(Po_Msg), c: ^Po_Clip) {
	ui.tree.clipboard = {
		user = c,
		set  = proc(user: rawptr, text: string) -> bool { return true },
		get  = proc(user: rawptr, allocator := context.allocator) -> (string, bool) {
			c := (^Po_Clip)(user)
			if len(c.text) == 0 do return "", false
			return strings.clone(c.text, allocator), true
		},
		types = proc(user: rawptr, allocator := context.allocator) -> []string { return (^Po_Clip)(user).offered },
	}
}

// po_build puts a composer on screen, asking for the hook when `hook`.
@(private = "file")
po_build :: proc(ui: ^Ui(Po_Msg), doc: ^Document, hook: bool) -> Node {
	set_viewport(&ui.tree, {400, 300})
	begin_view(ui)
	n := text_area(ui, doc, "Message")
	if hook {
		editor_options(ui, n, on_paste_other = proc(e: Ev(Paste_Other)) -> Po_Msg { return e.value })
	} else {
		editor_options(ui, n)
	}
	end_view(ui)
	frame(&ui.tree, {400, 300})
	set_focus(&ui.tree, n, false)
	return n
}

@(private = "file")
po_paste :: proc(ui: ^Ui(Po_Msg), n: Node) -> bool {
	return editor_action(ui, n, .Paste)
}

@(test)
a_pasted_picture_reaches_the_app :: proc(t: ^testing.T) {
	ui: Ui(Po_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	doc := document_make("")
	defer document_destroy(&doc)
	clip: Po_Clip
	po_install(&ui, &clip)
	n := po_build(&ui, &doc, hook = true)

	// a screenshot: nothing to insert, so the app hears what is there
	clip.offered = {"image/png"}
	testing.expect(t, po_paste(&ui, n), "the paste was taken")
	testing.expect_value(t, len(ui.msgs), 1)
	other, got := ui.msgs[0].(Paste_Other)
	testing.expect(t, got, "a Paste_Other message")
	testing.expect(t, other.picture && !other.files, "a picture, no files")
	testing.expect_value(t, document_text(&doc, context.temp_allocator), "") // and nothing typed
	clear(&ui.msgs)

	// files from a file manager
	clip.offered = {MIME_URI_LIST, MIME_GNOME_FILES}
	testing.expect(t, po_paste(&ui, n), "the paste was taken")
	testing.expect_value(t, len(ui.msgs), 1)
	other = ui.msgs[0].(Paste_Other)
	testing.expect(t, other.files && !other.picture, "files, no picture")
	clear(&ui.msgs)

	// both on offer (a file manager with a thumbnail): the app is told both
	clip.offered = {"image/png", MIME_URI_LIST}
	testing.expect(t, po_paste(&ui, n))
	other = ui.msgs[0].(Paste_Other)
	testing.expect(t, other.picture && other.files, "both")
	testing.expect_value(t, len(other.mimes), 2) // every form, for an app that reads its own
	clear(&ui.msgs)

	// text still types, and says nothing to the app
	clip.text = "hello"
	clip.offered = {"image/png", MIME_TEXT_UTF8}
	testing.expect(t, po_paste(&ui, n), "the paste was taken")
	testing.expect_value(t, document_text(&doc, context.temp_allocator), "hello")
	testing.expect_value(t, len(ui.msgs), 0)

	// nothing on the clipboard at all: the paste is still a no-op
	clip.text = ""
	clip.offered = {}
	testing.expect(t, !po_paste(&ui, n), "nothing to paste")
	testing.expect_value(t, len(ui.msgs), 0)
}

@(test)
an_editor_that_asked_for_nothing_is_unchanged :: proc(t: ^testing.T) {
	ui: Ui(Po_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	doc := document_make("")
	defer document_destroy(&doc)
	clip := Po_Clip{offered = {"image/png"}}
	po_install(&ui, &clip)
	n := po_build(&ui, &doc, hook = false)

	testing.expect(t, !po_paste(&ui, n), "a picture is nothing to an editor that takes text")
	testing.expect_value(t, len(ui.msgs), 0)
	testing.expect_value(t, editor_actions(&ui.tree, n), Editor_Actions{}) // and the menu does not offer Paste
}

@(test)
the_menu_offers_paste_when_ctrl_v_would_take_it :: proc(t: ^testing.T) {
	// the same key and the same menu item do the same thing: an editor that
	// takes a pasted picture offers Paste for one
	ui: Ui(Po_Msg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	doc := document_make("")
	defer document_destroy(&doc)
	clip := Po_Clip{offered = {"image/png"}}
	po_install(&ui, &clip)
	n := po_build(&ui, &doc, hook = true)

	testing.expect_value(t, editor_actions(&ui.tree, n), Editor_Actions{.Paste})

	// a read-only view takes no paste at all, hook or not
	editor_options(&ui, n, readonly = true)
	testing.expect_value(t, editor_actions(&ui.tree, n), Editor_Actions{})
	testing.expect(t, !po_paste(&ui, n), "read-only")
	testing.expect_value(t, len(ui.msgs), 0)
}

} // when ODIN_TEST