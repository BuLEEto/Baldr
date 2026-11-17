// 34_mentions — a composer whose @ offers the files in a project.
//
// `editor_complete(ui, ed, files, trigger = '@')` on a plain `text_area`:
// typing `@` at the start of a word opens the completion list under the
// caret, what follows is the query, Up / Down pick, Enter or Tab accept —
// and Enter does not send the message while the list is open.
//
//	./build.sh example 34_mentions run
package main

import "core:fmt"
import "core:strings"
import "baldr:baldr"

File :: struct {
	name, folder: string,
}

// What the project has in it. A real app would read a folder.
FILES := []File{
	{"Stock check.xlsx", "reports/ · 2 days ago"},
	{"stock-notes.md", "notes/ · today"},
	{"Readme.md", "· last week"},
	{"Invoice 4471.pdf", "invoices/ · March"},
	{"kitchen-plan.png", "pictures/ · last year"},
	{"shopping.txt", "· yesterday"},
}

State :: struct {
	draft: baldr.Document,
	sent:  [dynamic]string,
}

Msg :: union {
	Send,
	Edited,
}

Send   :: struct {}
Edited :: struct {}

init :: proc() -> (s: State) {
	s.draft = baldr.document_make("")
	return
}

update :: proc(s: ^State, msg: Msg) -> baldr.Cmd(Msg) {
	switch m in msg {
	case Send:
		line := strings.trim_space(baldr.document_text(&s.draft, context.temp_allocator))
		if line != "" {
			append(&s.sent, strings.clone(line))
			baldr.document_replace(&s.draft, {0, 0}, baldr.document_end(&s.draft), "")
		}
	case Edited:
	}
	return {}
}

// files_for is the app's completer: the project's files whose name contains
// what has been typed after the `@`. The strings may be temporary — the
// editor copies what it keeps.
files_for :: proc(doc: ^baldr.Document, at: baldr.Pos, prefix: string, lang: ^baldr.Language, out: ^[dynamic]baldr.Completion) {
	q := strings.to_lower(prefix, context.temp_allocator)
	for f in FILES {
		if q != "" && !strings.contains(strings.to_lower(f.name, context.temp_allocator), q) do continue
		// What goes into the text: quoted when the name has a space in it,
		// and a space after, so the next word is not part of the mention.
		insert := fmt.tprintf("@%q " if strings.contains(f.name, " ") else "@%s ", f.name)
		append(out, baldr.Completion{label = f.name, insert = insert, detail = f.folder})
	}
}

view :: proc(s: ^State, ui: ^baldr.Ui(Msg)) {
	baldr.column(ui, padding = .lg, gap = .md, flex = 1); defer baldr.end(ui)
	baldr.text(ui, "Mentions", role = .Headline)
	baldr.text(ui, "Type @ to mention a file. Enter sends; while the list is open Enter picks instead.", muted = true)

	baldr.scroll(ui, flex = 1, gap = .sm); {
		defer baldr.end(ui)
		if len(s.sent) == 0 do baldr.text(ui, "Nothing sent yet.", muted = true)
		for line, i in s.sent {
			baldr.card(ui, padding = .md, elevation = .Low, key = u64(i + 1)); {
				defer baldr.end(ui)
				baldr.text(ui, line)
			}
		}
	}

	box := baldr.text_area(ui, &s.draft, placeholder = "Message… (@ for a file)", label = "Message",
		on_change = Msg(Edited{}), on_submit = Msg(Send{}), height = 96, key = 1)
	baldr.editor_options(ui, box, submit = .Enter) // a composer: plain Enter sends
	baldr.editor_complete(ui, box, files_for, trigger = '@')
}

main :: proc() {
	err := baldr.run(baldr.App(State, Msg){
		app_id = "dev.baldr.mentions",
		title  = "Mentions",
		size   = {620, 520},
		start  = proc(s: ^State) -> baldr.Cmd(Msg) { return baldr.focus(Msg, 1) }, // the composer has the keyboard
		init   = init,
		update = update,
		view   = view,
	})
	if err != .None do fmt.eprintln("exit:", err)
}
