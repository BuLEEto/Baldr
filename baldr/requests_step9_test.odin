package baldr

@(require) import "core:mem"
@(require) import "core:strings"
@(require) import "core:testing"

// Test files are part of the package, so everything that imports Baldr
// type-checks them too; behind this `when` an app does not pay for them.
// ODIN_TEST is set by `odin test`; BALDR_TESTS lets ./build.sh check look
// inside too.
when ODIN_TEST || #config(BALDR_TESTS, false) {

// A menu that opens where a drop landed, and a password field that leaves
// no passphrase behind.


@(private = "file")
RequestsStep9_PMsg :: struct { kind: enum { None, Drop, Close }, action: Drop_Action }

@(private = "file")
drop_view :: proc(ui: ^Ui(RequestsStep9_PMsg), menu: bool) -> (source, folder: Node) {
	set_viewport(&ui.tree, {500, 300})
	begin_view(ui)
	column(ui, gap = .lg, padding = .lg)
	source = button(ui, "notes.txt", RequestsStep9_PMsg{}, key = 1)
	draggable(ui, source, "file", tag = 1)
	folder = button(ui, "Projects", RequestsStep9_PMsg{}, key = 2)
	drop_target(ui, folder, proc(e: Ev(Drop)) -> RequestsStep9_PMsg { return {kind = .Drop, action = e.value.action} }, accepts = "file")
	if context_menu(ui, menu, RequestsStep9_PMsg{kind = .Close}) {
		menu_item(ui, "Copy here", RequestsStep9_PMsg{})
		menu_item(ui, "Move here", RequestsStep9_PMsg{})
		end(ui)
	}
	end(ui)
	end_view(ui)
	frame(&ui.tree, {500, 300})
	return
}

@(private = "file")
menu_at :: proc(ui: ^Ui(RequestsStep9_PMsg)) -> (at: [2]f32, ok: bool) {
	for c := node_first(&ui.tree, ui.tree.overlay); c != NODE_NONE; c = node_next(&ui.tree, c) {
		if node_get(&ui.tree, c).access.role == .Menu do return ui.tree.overlay_rules[c].at, true
	}
	return
}

@(test)
a_menu_opens_where_the_drop_landed :: proc(t: ^testing.T) {
	ui: Ui(RequestsStep9_PMsg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	source, folder := drop_view(&ui, false)
	sd, fd := node_get(&ui.tree, source), node_get(&ui.tree, folder)
	p := [2]f32{sd.abs.x + sd.abs.w / 2, sd.abs.y + sd.abs.h / 2}
	ui.context_pos = {1, 1} // an old right-click somewhere else
	pointer_button(&ui, .Left, true, p)
	pointer_move(&ui, p + {12, 0})
	land := [2]f32{fd.abs.x + 11, fd.abs.y + 5}
	pointer_move(&ui, land)
	ui.pointer.mods = {.Alt} // Alt-drop: ask
	pointer_button(&ui, .Left, false, land)
	ui.pointer.mods = {}
	testing.expect(t, len(ui.msgs) == 1 && ui.msgs[0].kind == .Drop && ui.msgs[0].action == .Ask, "an Alt-drop asks")
	testing.expect_value(t, ui.context_pos, land)
	drop_view(&ui, true)
	at, ok := menu_at(&ui)
	testing.expect(t, ok, "the menu is open")
	testing.expect_value(t, at, land) // Copy here / Move here, where it landed
	clear(&ui.msgs)
	drop_view(&ui, false)

	set_focus(&ui.tree, source, true) // from the keyboard: Ctrl+X, then Ctrl+V on the folder
	testing.expect(t, key_event(&ui, .X, true, {.Ctrl}))
	set_focus(&ui.tree, folder, true)
	ui_after_events(&ui, 1000)
	testing.expect(t, key_event(&ui, .V, true, {.Ctrl}))
	testing.expect(t, len(ui.msgs) == 1 && ui.msgs[0].kind == .Drop)
	fd = node_get(&ui.tree, folder)
	testing.expect_value(t, ui.context_pos, [2]f32{fd.abs.x + min(fd.abs.w / 2, 24), fd.abs.y + fd.abs.h / 2})
}

// An allocator that counts blocks freed (or moved away from) with bytes
// still in them.
@(private = "file")
Freed :: struct { backing: mem.Allocator, dirty: int }

@(private = "file")
freed_check :: proc(data: rawptr, mode: mem.Allocator_Mode, size, alignment: int, old_memory: rawptr, old_size: int, loc := #caller_location) -> ([]byte, mem.Allocator_Error) {
	f := (^Freed)(data)
	#partial switch mode {
	case .Free, .Resize, .Resize_Non_Zeroed:
		if old_memory != nil && old_size > 0 {
			for b in mem.byte_slice(old_memory, old_size) do if b != 0 {
				f.dirty += 1
				break
			}
		}
	}
	return f.backing.procedure(f.backing.data, mode, size, alignment, old_memory, old_size, loc)
}

@(private = "file")
PASS :: "correct horse battery staple, twice over"

@(private = "file")
type_in :: proc(tx: ^Text) {
	pass := PASS
	for i in 0 ..< len(pass) do text_insert(tx, len(tx.buf), pass[i:i + 1]) // a keystroke at a time, as typed
}

@(private = "file")
all_zero :: proc(b: []u8) -> bool {
	for x in b do if x != 0 do return false
	return true
}

@(test)
a_secret_text_leaves_no_passphrase_behind :: proc(t: ^testing.T) {
	plain := Freed{backing = context.allocator}
	{
		context.allocator = mem.Allocator{freed_check, &plain}
		tx: Text
		type_in(&tx)
		text_destroy(&tx)
	}
	testing.expect(t, plain.dirty > 0, "a plain Text's outgrown blocks keep what they held (what this fixes)")

	secret := Freed{backing = context.allocator}
	{
		context.allocator = mem.Allocator{freed_check, &secret}
		tx := Text{secret = true}
		type_in(&tx)
		testing.expect_value(t, str(tx), PASS)
		old := len(tx.buf)
		text_delete(&tx, 0, len("correct "))
		room := mem.byte_slice(raw_data(tx.buf), cap(tx.buf))
		testing.expect(t, all_zero(room[len(tx.buf):old]), "deleted bytes are zeroed")
		old = len(tx.buf)
		text_set(&tx, "short")
		room = mem.byte_slice(raw_data(tx.buf), cap(tx.buf))
		testing.expect(t, str(tx) == "short" && all_zero(room[len(tx.buf):old]), "a replaced secret is zeroed")
		text_destroy(&tx)
	}
	testing.expectf(t, secret.dirty == 0, "a secret Text frees only zeroed blocks (%d were not)", secret.dirty)

	tx := text_make("hunter2")
	text_reserve(&tx, 256)
	testing.expect(t, cap(tx.buf) >= 256 && str(tx) == "hunter2", "reserve keeps the contents")
	text_scrub(&tx)
	testing.expect(t, len(tx.buf) == 0 && all_zero(mem.byte_slice(raw_data(tx.buf), cap(tx.buf))), "scrub zeroes all its room")
	text_destroy(&tx)
}

@(private = "file")
Clip_Spy :: struct { copies: int, pasted: string }

@(private = "file")
pw_view :: proc(ui: ^Ui(RequestsStep9_PMsg), pw, plain: ^Text) -> (field, other: Node) {
	set_viewport(&ui.tree, {500, 200})
	begin_view(ui)
	column(ui, gap = .sm, padding = .md)
	field = text_input(ui, pw, label = "Passphrase", password = true)
	other = text_input(ui, plain, label = "Name")
	end(ui)
	end_view(ui)
	frame(&ui.tree, {500, 200})
	return
}

@(test)
a_password_field_keeps_its_passphrase_off_the_clipboard :: proc(t: ^testing.T) {
	ui: Ui(RequestsStep9_PMsg)
	ui_init(&ui)
	defer ui_destroy(&ui)
	pw, plain: Text
	defer text_destroy(&pw)
	defer text_destroy(&plain)
	spy: Clip_Spy
	ui.tree.clipboard = {
		user = &spy,
		set = proc(user: rawptr, text: string) -> bool {
			(^Clip_Spy)(user).copies += 1
			return true
		},
		get = proc(user: rawptr, allocator := context.allocator) -> (string, bool) {
			s := (^Clip_Spy)(user)
			s.pasted = strings.clone("from a manager", allocator)
			return s.pasted, true
		},
	}
	field, other := pw_view(&ui, &pw, &plain)
	set_focus(&ui.tree, field, true)
	text_event(&ui, "hunter2")
	testing.expect(t, pw.secret, "a password field's Text is secret")
	key_event(&ui, .A, true, {.Ctrl})
	key_event(&ui, .C, true, {.Ctrl})
	key_event(&ui, .X, true, {.Ctrl})
	testing.expect_value(t, spy.copies, 0) // never to the clipboard
	testing.expect_value(t, str(pw), "hunter2") // and nothing cut
	key_event(&ui, .V, true, {.Ctrl}) // pasting in still works
	testing.expect_value(t, str(pw), "from a manager")
	testing.expect(t, all_zero(transmute([]u8)spy.pasted), "the pasted copy is zeroed")

	set_focus(&ui.tree, other, true)
	text_event(&ui, "Alex")
	key_event(&ui, .A, true, {.Ctrl})
	key_event(&ui, .C, true, {.Ctrl})
	testing.expect_value(t, spy.copies, 1) // an ordinary field still copies
	testing.expect(t, !plain.secret)
}

} // when ODIN_TEST