// 10_files — a note kept in a file. Read at start (read_file from `start`), saved from
// a button (write_file), reloaded when something else writes it (a watch
// subscription), a clock from an every-second timer, and a "Saved"
// notice a delay clears. Nothing here waits on the disk: the IO thread
// does the work and the outcomes arrive as messages.
//
// Closing the window with unsaved edits asks first (App.on_close): Baldr
// refuses the close and hands the app a message, so the dialog is an
// ordinary part of the view and the app is what ends the run.
//
//   ./build.sh example 10_files run     # then: echo "edited outside" >> notes.txt
package main

import "core:fmt"
import "core:os"
import "core:time"
import "baldr:baldr"

PATH :: "notes.txt"

State :: struct {
	doc:    baldr.Document,
	notice: string,
	clock:  string,
	dirty:  bool, // edited here since the last load or save
	saving: bool,
	asking: bool, // the window was closed with edits in it: the dialog is up
}

Msg :: union {
	Loaded,
	Edited,
	Save,
	Saved,
	Changed,
	Tick,
	Clear,
	Closing,
	Discard,
	Keep,
}
Loaded  :: struct { ok: bool, text: string, error: string }
Edited  :: struct {}
Save    :: struct {}
Saved   :: struct { ok: bool, error: string }
Changed :: struct { kind: baldr.Change_Kind }
Tick    :: struct {}
Clear   :: struct {}
Closing :: struct {} // App.on_close: the person closed the window
Discard :: struct {}
Keep    :: struct {}

load :: proc() -> baldr.Cmd(Msg) {
	return baldr.read_file(Msg, PATH, proc(e: baldr.Ev(baldr.File_Read)) -> Msg {
		return Loaded{e.value.ok, string(e.value.data), e.value.error} // the data lives until update returns
	})
}

update :: proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) {
	switch v in m {
	case Loaded:
		if v.ok {
			baldr.document_set_text(&s.doc, v.text) // copies
			s.notice = "Loaded from disk"
		} else {
			s.notice = fmt.aprintf("Nothing to load (%s): start typing", v.error)
		}
		s.dirty = false
		return baldr.delay(Msg, 2000, Clear{})
	case Edited: s.dirty = true
	case Save:
		s.saving = true
		text := baldr.document_text(&s.doc, context.temp_allocator)
		return baldr.write_file(Msg, PATH, transmute([]u8)text, proc(e: baldr.Ev(baldr.File_Written)) -> Msg { return Saved{e.value.ok, e.value.error} })
	case Saved:
		s.saving = false
		s.dirty = !v.ok
		s.notice = "Saved" if v.ok else fmt.aprintf("Save failed: %s", v.error)
		// Save in the close dialog means save *and then* close — but only
		// when the write actually worked. A failed save that closed anyway
		// would lose the very edits the dialog was protecting.
		if s.asking {
			if v.ok do return baldr.quit(Msg)
			s.asking = false // the dialog steps aside so the error can be read
		}
		return baldr.delay(Msg, 2000, Clear{})
	case Changed:
		if s.saving do return {} // our own write
		if s.dirty {
			s.notice = "Changed on disk (unsaved edits kept)"
			return {}
		}
		return load()
	case Tick:
		h, mi, sec := time.clock_from_time(time.now())
		s.clock = fmt.aprintf("%02d:%02d:%02d UTC", h, mi, sec)
	case Clear: s.notice = ""
	// App.on_close means the window did *not* close: the app decides. With
	// nothing unsaved there is nothing to ask about, so this ends the run
	// itself — the dialog is for the one case that needs it.
	case Closing:
		if !s.dirty do return baldr.quit(Msg)
		s.asking = true
	case Discard: return baldr.quit(Msg)
	case Keep:    s.asking = false
	}
	return {}
}

// The app listens for as long as these lines are declared.
subscriptions :: proc(s: ^State, out: ^[dynamic]baldr.Sub(Msg)) {
	append(out, baldr.every(Msg, 1000, Tick{}))
	append(out, baldr.watch(Msg, PATH, proc(e: baldr.Ev(baldr.File_Change)) -> Msg { return Changed{e.value.kind} }))
}

view :: proc(s: ^State, ui: ^baldr.Ui(Msg)) {
	// Ctrl+W closes the window, and means the same as the title bar's
	// button: ask first if there is anything to lose.
	baldr.shortcut(ui, "Ctrl+W", Msg(Closing{}))
	baldr.column(ui, flex = 1, padding = .xl, gap = .md); defer baldr.end(ui)
	baldr.row(ui, align = .Center, gap = .md); {
		defer baldr.end(ui)
		baldr.text(ui, "Notes", role = .Headline)
		baldr.spacer(ui)
		baldr.text(ui, s.clock, role = .Label, muted = true)
	}
	baldr.text(ui, "Kept in notes.txt next to the program. Edit it in another program and it reloads here.", muted = true)
	baldr.text_area(ui, &s.doc, placeholder = "Write something…", on_change = Msg(Edited{}), label = "Note", flex = 1)
	baldr.row(ui, align = .Center, gap = .md); {
		defer baldr.end(ui)
		baldr.button(ui, "Save" if s.dirty else "Saved", Save{}, disabled = !s.dirty || s.saving)
		baldr.text(ui, s.notice, role = .Label, muted = true)
	}

	// The window is still open — Baldr refused the close and told the app
	// instead — so the dialog is an ordinary part of the view.
	if baldr.dialog(ui, s.asking, Msg(Keep{}), title = "Close without saving?") {
		defer baldr.end(ui)
		baldr.text(ui, "This note has edits that are not in notes.txt yet.")
		baldr.row(ui, gap = .sm, justify = .End); {
			defer baldr.end(ui)
			baldr.button(ui, "Cancel", Msg(Keep{}), variant = .Outline)
			baldr.button(ui, "Discard", Msg(Discard{}), variant = .Danger)
			// Enter saves: the safe answer is the default one (build.odin)
			baldr.button(ui, "Save", Msg(Save{}), default = true)
		}
	}
}

main :: proc() {
	// An app that keeps something worth keeping should carry the run's
	// answer out: `.Disconnected` means the desktop dropped us rather than
	// the person closing the window, and exiting 0 on that hides it.
	if err := run_app(); err != .None do os.exit(1)
}

run_app :: proc() -> baldr.Error {
	return baldr.run(baldr.App(State, Msg){
		title  = "Baldr — files",
		app_id = "dev.baldr.files",
		size   = {520, 420},
		init   = proc() -> State { return {doc = baldr.document_make("")} },
		start  = proc(s: ^State) -> baldr.Cmd(Msg) { return load() },
		update = update,
		view   = view,
		// Without this the title bar's button would end the run with the
		// edits still only in memory. With it the window stays open and the
		// app is asked first.
		on_close = Msg(Closing{}),
		subscriptions = subscriptions,
	})
}
