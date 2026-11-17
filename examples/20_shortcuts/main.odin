package main

// Rebinding a shortcut by pressing it: click a row, press the
// chord, and it is written down — including the ones the desktop would
// normally act on itself, because a capture asks the compositor to hold its
// shortcuts off while it listens. Escape cancels the row, Backspace clears
// the binding.

import "core:fmt"
import "core:strings"
import "baldr:baldr"

Action :: struct {
	name:  string,
	chord: string, // as a person reads it
	keysym: string, // as keybinds.conf would write it: "Super+q"
}

State :: struct {
	actions:  [5]Action,
	editing:  int, // the row listening, -1 when none
	pending:  string, // the chord being pressed, while it is held
}

Edit    :: struct { row: int }
Pressed :: struct { chord: baldr.Chord }
Msg :: union { Edit, Pressed }

init :: proc() -> State {
	return State{
		editing = -1,
		actions = {
			{name = "Close window",     chord = "Super+Q",     keysym = "Super+q"},
			{name = "Overview",         chord = "Super+A",     keysym = "Super+a"},
			{name = "Screenshot",       chord = "Print",       keysym = "Print"},
			{name = "Volume up",        chord = "Volume Up",   keysym = "XF86AudioRaiseVolume"},
			{name = "Terminal",         chord = "Super+Enter", keysym = "Super+Return"},
		},
	}
}

view :: proc(s: ^State, ui: ^baldr.Ui(Msg)) {
	// While a row is listening, every chord comes here instead of reaching
	// the window — and the desktop is asked to stop acting on its own.
	baldr.key_capture(ui, s.editing >= 0, proc(e: baldr.Ev(baldr.Chord)) -> Msg {
		return Pressed{e.value}
	})

	baldr.column(ui, padding = .lg, gap = .md); defer baldr.end(ui)
	baldr.text(ui, "Keyboard shortcuts", role = .Title)
	baldr.text(ui, "Click a shortcut, then press the keys you want." if s.editing < 0 else "Press the keys. Escape cancels, Backspace clears.", muted = true)

	for a, i in s.actions {
		row := baldr.row(ui, gap = .md, align = .Center, key = u64(i + 1)); {
			defer baldr.end(ui)
			baldr.text(ui, a.name)
			baldr.spacer(ui)
			if s.editing == i {
				shown := s.pending if s.pending != "" else "Press a key…"
				baldr.button(ui, shown, Msg(Edit{-1}), variant = .Primary)
			} else {
				baldr.button(ui, a.chord if a.chord != "" else "Not bound", Msg(Edit{i}), variant = .Outline)
			}
		}
	}

	baldr.text(ui, "keybinds.conf would say:", role = .Caption, muted = true)
	for a in s.actions do if a.keysym != "" do baldr.text(ui, fmt.tprintf("  bind %s", a.keysym), role = .Caption, muted = true)
}

update :: proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) {
	switch v in m {
	case Edit:
		s.editing = v.row
		s.pending = ""
	case Pressed:
		c := v.chord
		if c.held { // only modifiers so far: show the chord forming
			s.pending = strings.clone(baldr.chord_text(c), context.allocator)
			return {}
		}
		defer { s.editing = -1; s.pending = "" }
		if s.editing < 0 do return {}
		#partial switch c.key {
		case .Escape: return {} // cancelled: the binding stays as it was
		case .Backspace:
			s.actions[s.editing].chord = ""
			s.actions[s.editing].keysym = ""
			return {}
		}
		s.actions[s.editing].chord = strings.clone(baldr.chord_text(c), context.allocator)
		s.actions[s.editing].keysym = strings.clone(keysym_line(c), context.allocator)
	}
	return {}
}

// keysym_line writes the chord the way a compositor's configuration file
// does: the modifiers it names, then the platform's own key name.
keysym_line :: proc(c: baldr.Chord) -> string {
	b := strings.builder_make(context.temp_allocator)
	if .Ctrl in c.mods do strings.write_string(&b, "Ctrl+")
	if .Alt in c.mods do strings.write_string(&b, "Alt+")
	if .Shift in c.mods do strings.write_string(&b, "Shift+")
	if .Super in c.mods do strings.write_string(&b, "Super+")
	strings.write_string(&b, c.keysym if c.keysym != "" else "?")
	return strings.to_string(b)
}

main :: proc() {
	baldr.run(baldr.App(State, Msg){
		title = "Shortcuts", app_id = "baldr.shortcuts", size = {560, 440},
		init = init, view = view, update = update,
	})
}
