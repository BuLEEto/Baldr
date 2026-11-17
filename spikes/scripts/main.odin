package main

// Text in every script. File names, song titles and window
// titles in scripts the toolkit's own fonts do not have, drawn from the
// system's fonts: at two sizes, in list rows among Latin ones (their height
// and baseline must match), bold, and in a text field (the caret between
// characters it measures through the same path).

import "baldr:baldr"

State :: struct {
	field: baldr.Text,
}

Msg :: enum { None }

NAMES := [?]string{
	"Quarterly report.pdf",
	"日本語のファイル名.txt",
	"שיר ערש.mp3",
	"أغنية جميلة.flac",
	"नमस्ते दुनिया.md",
	"สวัสดีชาวโลก.odt",
	"안녕하세요.png",
	"Ωμέγα — Ѯ — ა.txt",
	"Holiday photos",
}

view :: proc(s: ^State, ui: ^baldr.Ui(Msg)) {
	baldr.row(ui, flex = 1, gap = .xl, padding = .lg); defer baldr.end(ui)
	{
		baldr.column(ui, gap = .none, width = 330); defer baldr.end(ui)
		for n, i in NAMES do baldr.list_row(ui, n, Msg.None, icon = .File_Text, detail = "12 KB", key = u64(i + 1))
	}
	{
		baldr.column(ui, gap = .md, flex = 1); defer baldr.end(ui)
		baldr.text(ui, "東京 · 서울 · القاهرة · תל אביב", role = .Headline)
		baldr.text(ui, "日本語と English が混ざった文", weight = .Semibold)
		baldr.text(ui, "スピッツ — ロビンソン (1995)")
		baldr.text(ui, "فيروز — نسم علينا الهوى", muted = true)
		baldr.text_input(ui, &s.field, label = "Search", width = 300, focus = true) // the caret after mixed text: measured through the same path
	}
}

main :: proc() {
	baldr.run(baldr.App(State, Msg){
		title = "Scripts", app_id = "dev.baldr.scripts", size = {860, 500},
		init = proc() -> (s: State) {
			s.field = baldr.text_make("東京タワー and more")
			return
		},
		view = view,
		update = proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) { return {} },
	})
}
