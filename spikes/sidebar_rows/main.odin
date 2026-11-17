package main

// A messenger's sidebar. An unread row shows its count, draws its
// last message in the ordinary colour, puts its time in the accent and
// shows the start bar; a search result shows which words matched; and a
// tab asks to be noticed until you look at it.
//
//	./build.sh spike sidebar_rows run

import "core:strings"
import "baldr:baldr"

Msg :: union { Pick, Tab }
Pick :: struct { i: int }
Tab  :: struct { i: int }

State :: struct { tab: int }

SNIPPET :: "see you at the bridge then"

main :: proc() {
	baldr.run(baldr.App(State, Msg){
		title = "sidebar rows", app_id = "baldr.sidebar_rows", size = {420, 520},
		update = proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) {
			if v, ok := m.(Tab); ok do s.tab = v.i
			return {}
		},
		view = proc(s: ^State, ui: ^baldr.Ui(Msg)) {
			baldr.column(ui, padding = .md, gap = .sm); defer baldr.end(ui)

			labels := []string{"Chats", "Requests (3)"}
			tones := []baldr.Tone{.Neutral, .Danger}
			baldr.tab_bar(ui, s.tab, labels,
				on_change = proc(e: baldr.Ev(int)) -> Msg { return Tab{e.value} },
				tones = tones, key = 1)

			baldr.text(ui, "read, unread 1, unread 12, unread 100", role = .Caption, muted = true)
			baldr.column(ui, gap = .xxs)
			{
				defer baldr.end(ui)
				baldr.list_row(ui, "Ada Lovelace", Msg(Pick{0}), glyph = "A",
					detail = "thanks — that worked", value = "09:12", variant = .Avatar, key = 1)
				baldr.list_row(ui, "Bo Nielsen", Msg(Pick{1}), glyph = "B",
					detail = "are you free later?", value = "09:40", unread = 1, variant = .Avatar, key = 2)
				baldr.list_row(ui, "Design team", Msg(Pick{2}), glyph = "D",
					detail = "twelve new messages in here", value = "10:02", unread = 12, variant = .Avatar, key = 3)
				baldr.list_row(ui, "Noisy group", Msg(Pick{3}), glyph = "N",
					detail = "a hundred and counting", value = "10:15", unread = 100, variant = .Avatar, key = 4)
				baldr.list_row(ui, "Selected row", Msg(Pick{4}), glyph = "S",
					detail = "for comparison", value = "yesterday", selected = true, variant = .Avatar, key = 5)
			}

			baldr.text(ui, "a search result — the matched words stand out", role = .Caption, muted = true)
			at := strings.index(SNIPPET, "bridge")
			baldr.list_row(ui, "Ada Lovelace", Msg(Pick{5}), glyph = "A",
				detail = SNIPPET, detail_mark = {at, at + len("bridge")},
				value = "Mon", variant = .Avatar, key = 6)
		},
	})
}
