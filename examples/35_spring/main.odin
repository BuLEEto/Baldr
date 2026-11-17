package main

// 35_spring — spring-loaded folders. Pick up `report.pdf` and, without
// letting go, hold it over a folder for about three quarters of a second:
// the folder opens under the drag, and the drag carries on inside it. Hold
// it over a folder in there and it opens too, as deep as you like. Let go
// anywhere and the file lands in the folder you are standing in.
//
// It is the same gesture as a taskbar button that raises its window under
// a drag: you are not asking the thing to take the file, you are asking it
// to get out of the way.
//
// Two parts make it work, and the second is the easy one to miss:
//
//   baldr.drag_rest(ui, n, Msg(Enter{i}))   // the drag stood still here
//
// fires once, where the drag settles. The toolkit then works out the drop
// target again from where the pointer is standing — it has not moved, but
// what is under it has — so releasing the moment a folder opens drops the
// file *in* that folder rather than on the row that opened it.
//
// Escape cancels, as it does for any drag, and nothing springs open on
// the way home.
//
//   ./build.sh example 35_spring run

import "baldr:baldr"
import "core:fmt"

ROOT :: -1

Entry :: struct {
	name:   string,
	folder: bool,
	parent: int, // the folder it is in; ROOT at the top
}

State :: struct {
	entries: [dynamic]Entry,
	at:      int,    // the folder being shown
	note:    string, // what just happened, for the reader and for a screen reader (in note_buf when formatted: kept past this message, so the state's own)
	note_buf: [160]u8,
}

Msg :: union {
	Enter, // a drag rested on a folder: open it
	Up,
	Dropped,
}
Enter   :: struct { i: int }
Up      :: struct {}
Dropped :: struct { into: int }

start :: proc(s: ^State) -> baldr.Cmd(Msg) {
	s.entries = make([dynamic]Entry)
	append(&s.entries,
		Entry{"Photos", true, ROOT},
		Entry{"Work", true, ROOT},
		Entry{"report.pdf", false, ROOT},
		Entry{"2019", true, 0},
		Entry{"2020", true, 0},
		Entry{"Invoices", true, 1},
		Entry{"Seaside", true, 3},
	)
	s.at = ROOT
	s.note = "Drag report.pdf onto a folder and hold still."
	return {}
}

// path_of names the folder we are in, as a path.
path_of :: proc(s: ^State, i: int) -> string {
	if i == ROOT do return "Files"
	return fmt.tprintf("%s / %s", path_of(s, s.entries[i].parent), s.entries[i].name)
}

// paths_of gives the drag its payload. A real file manager would hand
// over the file's actual path; this one has nothing on disk to name.
paths_of :: proc(user: rawptr, tag: u64, count: int, allocator := context.allocator) -> []string {
	out := make([]string, 1, allocator)
	out[0] = "/tmp/report.pdf"
	return out
}

view :: proc(s: ^State, ui: ^baldr.Ui(Msg)) {
	baldr.column(ui, flex = 1, padding = .lg, gap = .md); defer baldr.end(ui)

	baldr.row(ui, gap = .sm, align = .Center); {
		defer baldr.end(ui)
		baldr.button(ui, "Up", Msg(Up{}), variant = .Ghost, size = .Small, disabled = s.at == ROOT)
		baldr.text(ui, path_of(s, s.at), role = .Title)
	}
	baldr.text(ui, s.note, role = .Caption, muted = true)

	list := baldr.column(ui, flex = 1, gap = .xs); {
		defer baldr.end(ui)
		// The folder's own space takes the drop as well, so letting go
		// anywhere inside it puts the file here — including in a folder
		// you sprang into that has nothing in it yet. A row inside takes
		// its own drop first: the innermost target under the pointer wins.
		baldr.drop_target(ui, list, Msg(Dropped{s.at}), accepts = "file")
		for e, i in s.entries {
			if e.parent != s.at do continue
			n := baldr.row(ui, padding = .sm, gap = .sm, align = .Center, radius = 6, key = u64(i + 1)); {
				defer baldr.end(ui)
				baldr.icon(ui, .Folder if e.folder else .File_Text)
				baldr.text(ui, e.name)
			}

			if e.folder {
				// Spring-loading: hold a drag still here and it opens.
				baldr.drag_rest(ui, n, Msg(Enter{i}))
				// …and it takes the drop as well, so letting go on a
				// folder puts the file in it without waiting.
				baldr.drop_target(ui, n, Msg(Dropped{i}), accepts = "file")
			} else {
				baldr.draggable(ui, n, "file", tag = u64(i), files = paths_of, user = s)
			}
		}
		baldr.spacer(ui)
	}
}

update :: proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) {
	switch v in m {
	case Enter:
		s.at = v.i
		s.note = fmt.bprintf(s.note_buf[:], "%s sprang open — keep holding, or let go to drop here", s.entries[v.i].name)
	case Up:
		if s.at != ROOT do s.at = s.entries[s.at].parent
		s.note = "Drag report.pdf onto a folder and hold still."
	case Dropped:
		for &e in s.entries do if !e.folder do e.parent = v.into
		s.at = v.into
		s.note = fmt.bprintf(s.note_buf[:], "report.pdf is in %s", path_of(s, v.into))
	}
	return {}
}

main :: proc() {
	baldr.run(baldr.App(State, Msg){
		title = "Spring-loaded folders",
		app_id = "dev.baldr.spring",
		size = {520, 460},
		start = start,
		view = view,
		update = update,
	})
}
