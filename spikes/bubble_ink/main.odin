package main

// An outgoing chat bubble is filled with the accent, so its text must be
// that fill's "on" colour: the theme's surface colours on it are about 1.6:1
// on a dark theme, and a selection over them cannot be seen.
//
//	BUBBLE_THEME=light|dim|dark ./build.sh spike bubble_ink run
//
// Each bubble shows body, muted, bold, inline code and a link, and the
// lower one is drawn with a selection across it.

import "core:os"
import "core:strings"
import "baldr:baldr"

Msg :: union { Link }
Link :: struct { href: string }

BODY :: "Shipping tonight — see the notes, run baldr.test first, and ping me at https://example.invalid/x if it breaks."

runs_for :: proc() -> []baldr.Run {
	body := BODY // a constant cannot be sliced with a variable index
	// bold "Shipping tonight", code "baldr.test", a link at the end
	code_at := strings.index(BODY, "baldr.test")
	link_at := strings.index(BODY, "https://")
	// Runs are cumulative spans, each ending where the next begins.
	out := make([]baldr.Run, 5)
	out[0] = {end = 16, attrs = {.Bold}}
	out[1] = {end = code_at}
	out[2] = {end = code_at + len("baldr.test"), attrs = {.Code}}
	out[3] = {end = link_at}
	out[4] = {end = len(BODY), attrs = {.Link}, href = body[link_at:]}
	return out
}

bubble :: proc(ui: ^baldr.Ui(Msg), inked: bool, key: u64) {
	th := &ui.tree.theme
	baldr.column(ui, padding = .md, gap = .xs, bg = th.color.primary if inked else th.color.surface_variant,
		radius = th.radius.lg, max_width = 420, key = key)
	defer baldr.end(ui)
	runs := runs_for()
	defer delete(runs)
	if inked {
		baldr.styled_text(ui, BODY, runs, ink = th.color.on_primary, on = th.color.primary,
			on_link = proc(e: baldr.Ev(string)) -> Msg { return Link{e.value} }, key = 1)
	} else {
		baldr.styled_text(ui, BODY, runs,
			on_link = proc(e: baldr.Ev(string)) -> Msg { return Link{e.value} }, key = 1)
	}
}

main :: proc() {
	mode := baldr.theme_dark()
	if v, _ := os.lookup_env("BUBBLE_THEME", context.temp_allocator); v == "light" {
		mode = baldr.theme_light()
	} else if v == "dim" {
		mode = baldr.theme_dim()
	}
	baldr.run(baldr.App(State, Msg){
		title = "bubble ink", app_id = "baldr.bubble_ink", size = {500, 420}, theme = mode,
		view = proc(s: ^State, ui: ^baldr.Ui(Msg)) {
			baldr.column(ui, padding = .lg, gap = .md); defer baldr.end(ui)
			baldr.text(ui, ui.tree.theme.name, role = .Caption, muted = true)
			baldr.text(ui, "outgoing — ink = on_primary", role = .Caption, muted = true)
			bubble(ui, true, 1)
			baldr.text(ui, "incoming — no ink, as before", role = .Caption, muted = true)
			bubble(ui, false, 2)
		},
		update = proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) { return {} },
	})
}

State :: struct {}
