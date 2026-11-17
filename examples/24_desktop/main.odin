package main

// A desktop: a grid that keeps each icon where it was put.
// The app owns the placement — `place_of` says which cell an item is in,
// a drag reports where it landed through `on_place`, and the app writes
// that down (a real desktop persists it to a file and reads it back at
// start-up). Everything else is the icon view as it always was: band
// select, Ctrl- and Shift-click, arrows — which here move by what the eye
// sees, not by index order — Space, Ctrl+A, Enter, F2, type-ahead.

import "baldr:baldr"
import "core:fmt"

MAX :: 32

Item :: struct {
	name: string,
	icon: baldr.Icon,
	cell: [2]int, // {-1, -1}: never placed, so the view flows it down the first free column
}

State :: struct {
	items: [dynamic]Item,
	sel:   baldr.Selection,
	note:  string,
}

Place   :: struct { n: int, items: [MAX]int, cells: [MAX][2]int }
Pick    :: struct { i: int }
Open    :: struct { i: int }
Tidy    :: struct {}
Quit    :: struct {}
Msg     :: union { Place, Pick, Open, Tidy, Quit }

place_of :: proc(user: rawptr, index: int) -> [2]int {
	s := (^State)(user)
	return s.items[index].cell if index >= 0 && index < len(s.items) else {-1, -1}
}

// The drag is over: copy what it reported out of the event, which is only
// alive while the message is handled. A desktop with more icons than this
// one would clone the two slices instead of filling fixed arrays.
placed :: proc(e: baldr.Ev(baldr.Place_Drop)) -> Msg {
	m := Place{n = min(len(e.value.items), MAX)}
	for k in 0 ..< m.n {
		m.items[k] = e.value.items[k]
		m.cells[k] = e.value.cells[k]
	}
	return m
}

view :: proc(s: ^State, ui: ^baldr.Ui(Msg)) {
	baldr.column(ui, flex = 1); defer baldr.end(ui)

	baldr.row(ui, padding = .md, gap = .md, align = .Center); {
		defer baldr.end(ui)
		baldr.text(ui, "Desktop", role = .Title)
		baldr.spacer(ui)
		baldr.text(ui, s.note, muted = true)
		baldr.button(ui, "Tidy up", Msg(Tidy{}), variant = .Ghost, size = .Small)
	}

	first, last := baldr.icon_view(ui, len(s.items), &s.sel,
		place_of = place_of, place_user = s, on_place = placed,
		on_select = proc(e: baldr.Ev(int)) -> Msg { return Pick{e.value} },
		on_activate = proc(e: baldr.Ev(int)) -> Msg { return Open{e.value} },
		drag = "files", label = "Desktop"); {
		defer baldr.end(ui)
		for i in first ..< last do baldr.icon_item(ui, i, s.items[i].icon, s.items[i].name)
	}
}

update :: proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) {
	switch v in m {
	case Place:
		for k in 0 ..< v.n do s.items[v.items[k]].cell = v.cells[k]
		s.note = fmt.aprintf("%s moved to column %d, row %d",
			s.items[v.items[0]].name if v.n == 1 else fmt.tprintf("%d icons", v.n), v.cells[0].x, v.cells[0].y)
	case Pick:
		s.note = s.items[v.i].name if v.i >= 0 && v.i < len(s.items) else ""
	case Open:
		s.note = fmt.aprintf("Opening %s…", s.items[v.i].name)
	case Tidy:
		for &it in s.items do it.cell = {-1, -1} // unplaced again: the view flows them down the columns
		s.note = "Tidied"
	case Quit:
		return baldr.quit(Msg)
	}
	return {}
}

init :: proc() -> State {
	s := State{sel = baldr.selection_make(multi = true)}
	// an arrangement someone made: work on the left, today's thing at the
	// top of the second column, the rest never placed
	append(&s.items,
		Item{"Notes.md", .File_Text, {0, 0}},
		Item{"Budget.ods", .Table, {0, 1}},
		Item{"Plan.pdf", .File, {0, 2}},
		Item{"Today", .Folder, {2, 0}},
		Item{"Screenshots", .Folder, {2, 1}},
		Item{"holiday.jpg", .Image, {-1, -1}},
		Item{"scratch.txt", .File_Text, {-1, -1}},
		Item{"build.sh", .Terminal, {-1, -1}},
		Item{"Music", .Folder, {-1, -1}},
		Item{"report.docx", .File_Text, {-1, -1}},
	)
	return s
}

main :: proc() {
	baldr.run(baldr.App(State, Msg){
		title = "Desktop", app_id = "baldr.desktop", size = {760, 560},
		init = init, view = view, update = update,
	})
}
