// 07_code — the code editor: line numbers, tab stops, syntax colour from a
// Language, bracket matching, indentation keys, find (Ctrl+F) and go to
// line (Ctrl+G) on the same Document the text area edits, and a right-click
// menu that cuts, copies and pastes as the keys do.
//
//   ./build.sh example 07_code run
//
// An argument sets the code face to a family this machine has, the way a
// desktop style or a reader's own setting does — the editor re-lays its
// lines out in it, gutter and tab stops included:
//
//   ./build.sh example 07_code run "font:Liberation Mono"
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "baldr:baldr"

State :: struct {
	source:  baldr.Document,
	saved:   u64,       // the document version last "saved"
	menu:    bool,      // the editor's right-click menu is open
	menu_at: baldr.Pos, // …for this position
	pending: Maybe(baldr.Editor_Action), // what the menu chose, for the editor once it is built
}
Msg :: union { Edited, Save, Menu, Menu_Closed, Do }
Edited      :: struct { version: int }
Save        :: struct {}
Menu        :: struct { at: baldr.Pos }
Menu_Closed :: struct {}
Do          :: struct { action: baldr.Editor_Action }

update :: proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) {
	switch v in m {
	case Edited: // the document is edited in place; the version tells us it changed
	case Save:   s.saved = s.source.version
	case Menu:        s.menu, s.menu_at = true, v.at
	case Menu_Closed: s.menu = false
	case Do:          s.pending = v.action
	}
	return {}
}

view :: proc(s: ^State, ui: ^baldr.Ui(Msg)) {
	baldr.column(ui, flex = 1, padding = .lg, gap = .md); defer baldr.end(ui)
	baldr.row(ui, align = .Center, gap = .md); {
		defer baldr.end(ui)
		baldr.text(ui, "main.odin", role = .Title)
		if s.saved != s.source.version do baldr.text(ui, "• edited", muted = true)
		baldr.spacer(ui)
		baldr.button(ui, "Save", Msg(Save{}), icon = .Save, disabled = s.saved == s.source.version)
	}
	ed := baldr.code_editor(ui, &s.source, &baldr.LANG_ODIN, proc(e: baldr.Ev(int)) -> Msg { return Edited{e.value} },
		on_context = proc(e: baldr.Ev(baldr.Editor_Context)) -> Msg { return Menu{e.value.pos} }, label = "main.odin", flex = 1)
	if a, ok := s.pending.?; ok {
		baldr.editor_action(ui, ed, a)
		s.pending = nil
	}
	baldr.text(ui, fmt.tprintf("%d lines — Tab indents, Ctrl+/ comments, Ctrl+F finds, Ctrl+G goes to a line", baldr.block_count(&s.source)), role = .Caption, muted = true)

	if baldr.context_menu(ui, s.menu, Msg(Menu_Closed{})) {
		defer baldr.end(ui)
		can := baldr.editor_actions(&ui.tree, ed)
		items := [?]struct { label, keys: string, icon: baldr.Icon, action: baldr.Editor_Action } {
			{"Undo", "Ctrl+Z", .Undo_2, .Undo}, {"Redo", "Ctrl+Shift+Z", .Redo_2, .Redo},
			{"Cut", "Ctrl+X", .Scissors, .Cut}, {"Copy", "Ctrl+C", .Copy, .Copy}, {"Paste", "Ctrl+V", .Clipboard, .Paste},
			{"Select All", "Ctrl+A", .None, .Select_All},
		}
		for it, i in items {
			if i == 2 || i == 5 do baldr.separator(ui)
			baldr.menu_item(ui, it.label, Msg(Do{it.action}), shortcut = it.keys, icon = it.icon, disabled = it.action not_in can)
		}
		baldr.separator(ui)
		baldr.menu_item(ui, fmt.tprintf("Line %d, column %d", s.menu_at.block + 1, s.menu_at.off + 1), Msg(Menu_Closed{}), disabled = true)
	}
}

init :: proc() -> State {
	s := State{source = baldr.document_make(SAMPLE)}
	s.saved = s.source.version
	return s
}

// The code face this run was asked for, applied through `adjust_theme`
// rather than a theme of its own so the app still follows the desktop's
// light and dark. Cloned, because the theme keeps the name rather than
// copying it; the argument's own memory is the frame's.
@(private)
mono_want: string

adjust :: proc(th: ^baldr.Theme) {
	th.mono_family = mono_want
}

main :: proc() {
	app := baldr.App(State, Msg){title = "Code", app_id = "baldr.code", size = {760, 560}, init = init, update = update, view = view}
	for a in os.args[1:] {
		if !strings.has_prefix(a, "font:") do continue
		mono_want = strings.clone(strings.trim_space(a[5:]))
		app.adjust_theme = adjust
	}
	err := baldr.run(app)
	if err != .None do fmt.eprintln("exit:", err)
}

SAMPLE :: `package main

import "core:fmt"

// greet writes a line for every name.
greet :: proc(names: []string) {
	for name, i in names {
		fmt.printfln("%d: hello, %s", i + 1, name)
	}
}

main :: proc() {
	greet({"Baldr", "Skald", "Odin"})
}
`
