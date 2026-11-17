package main

// An app moves a text field's caret, and puts text in at it.
//
// A calculator's sum is a one-line field — typed, pasted and edited like
// any other — with a keypad beside it for the mouse and touch. A key has
// to go in *where the caret is*, as typing would, and the caret has to end
// up after it; otherwise "2" typed, "+" pressed and "3" typed gives "23+".
//
// Driven, because the proof is a sequence: every key press prints the
// value and the selection before and after, and `FIELD_CARET_KEYS` presses
// a list of them with no pointer at all (`7,+,3,=` or `2,+,3`), so the
// run can be read without clicking. Clicking the keys does the same thing.
//
//	build/field_caret                      # by hand, in the nested harness
//	FIELD_CARET_KEYS=2,+,3 build/field_caret
//	FIELD_CARET_KEYS=sin(,9 FIELD_CARET_QUIT=3 build/field_caret
//
// The keys come in three shapes: a digit and an operator
// (go in at the caret, caret after them), and `sin(` — which comes with
// its closing bracket and leaves the caret *between* them, which only
// text_input_set_selection can do.

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import "baldr:baldr"

KEYS :: []string{"7", "8", "9", "+", "sin(", "⌫"}

State :: struct {
	sum:     baldr.Text,
	field:   baldr.Node,
	t0:      time.Tick,
	queued:  []string, // keys to press without a pointer (FIELD_CARET_KEYS)
	at:      int,
	pending: string,   // a key the pointer pressed, applied by the next build
	quit_at: f64,
	presses: int,
}

Msg :: union { Key_Press, Tick, string }

Key_Press :: struct { key: string }

Tick :: struct {}

say :: proc(s: ^State, format: string, args: ..any) {
	fmt.eprintfln("field_caret: %7.3f s  %s", time.duration_seconds(time.tick_since(s.t0)), fmt.tprintf(format, ..args))
}

// press is what a keypad key does: the text goes in at the caret, and for
// a key that brings its own closing bracket the caret goes back between
// them. Backspace takes the character before the caret (or the selection).
press :: proc(s: ^State, ui: ^baldr.Ui(Msg), key: string) {
	lo, hi := baldr.text_input_selection(&ui.tree, s.field)
	s.presses += 1
	switch key {
	case "⌫":
		if lo == hi && lo > 0 {
			baldr.text_input_set_selection(&ui.tree, s.field, baldr.grapheme_prev(baldr.str(s.sum), lo), lo)
		}
		baldr.text_input_insert(ui, s.field, "")
	case "sin(":
		baldr.text_input_insert(ui, s.field, "sin()")
		_, after := baldr.text_input_selection(&ui.tree, s.field)
		baldr.text_input_set_selection(&ui.tree, s.field, after - 1, after - 1) // between the brackets
	case:
		baldr.text_input_insert(ui, s.field, key)
	}
	nlo, nhi := baldr.text_input_selection(&ui.tree, s.field)
	say(s, "key %-5q  [%d,%d] -> [%d,%d]  %q", key, lo, hi, nlo, nhi, baldr.str(s.sum))
}

update :: proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) {
	switch e in m {
	case Key_Press:
		// `update` has no tree — the field's node, its caret and its value
		// are the build's — so what the key does is written down here and
		// done in the next `view`, which happens in this same wake-up. It is
		// kept as a value: `s.queued = []string{e.key}` would store a slice
		// of a stack temporary.
		s.pending = e.key
	case Tick:
		secs := time.duration_seconds(time.tick_since(s.t0))
		if s.quit_at > 0 && secs >= s.quit_at do return baldr.quit(Msg)
		return baldr.delay(Msg, 150, Tick{})
	case string: // the field's own on_change: typed, pasted or our own insert
	}
	return {}
}

view :: proc(s: ^State, ui: ^baldr.Ui(Msg)) {
	baldr.column(ui, flex = 1, padding = .lg, gap = .md); defer baldr.end(ui)
	baldr.text(ui, "Sum", role = .Caption, muted = true)
	s.field = baldr.text_input(ui, &s.sum, width = 320, label = "Sum", key = 1,
		on_change = proc(e: baldr.Ev(string)) -> Msg { return e.value })
	{
		baldr.row(ui, gap = .sm); defer baldr.end(ui)
		for k, i in KEYS do baldr.button(ui, k, Msg(Key_Press{key = k}), variant = .Secondary, key = u64(i + 1))
	}
	baldr.text(ui, fmt.tprintf("%d key(s) pressed", s.presses), role = .Caption, muted = true)
	// Here is where the field's node is known, so this is where a key
	// pressed in `update` is applied, and where FIELD_CARET_KEYS' list is
	// worked through.
	if s.pending != "" {
		press(s, ui, s.pending)
		s.pending = ""
	}
	for s.at < len(s.queued) {
		press(s, ui, s.queued[s.at])
		s.at += 1
	}
}

main :: proc() {
	err := baldr.run(baldr.App(State, Msg){
		title = "Calculator", app_id = "dev.baldr.field_caret", size = {420, 240},
		init = proc() -> (s: State) {
			s.t0 = time.tick_now()
			baldr.text_set(&s.sum, os.get_env("FIELD_CARET_START", context.temp_allocator))
			if v := os.get_env("FIELD_CARET_KEYS", context.temp_allocator); v != "" {
				s.queued = strings.split(v, ",")
			}
			s.quit_at, _ = strconv.parse_f64(os.get_env("FIELD_CARET_QUIT", context.temp_allocator))
			fmt.eprintfln("field_caret: %d queued key(s); the keypad does the same by hand", len(s.queued))
			return
		},
		start = proc(s: ^State) -> baldr.Cmd(Msg) { return baldr.delay(Msg, 150, Tick{}) },
		update = update, view = view,
	})
	if baldr.run_failed(err) {
		fmt.eprintln("field_caret: exit:", err)
		os.exit(1)
	}
}
