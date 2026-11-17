// typing_cost: what does one keystroke cost in a long paragraph?
//
// A chat composer can hold one paragraph of ~1,800 characters. Keeping the
// caret in view needs caret_line, which shapes that whole paragraph, so
// doing it per edit makes typing O(n) a key and O(n^2) a message. This
// measures a burst of keys the way an input method commits one.
//
// With the reveal left to the layout after the burst, 200 keys into a
// 1,845-byte paragraph cost about 1.3 ms each plus one 24 ms layout: 0.3 s
// of work a second at ~230 keys/s, which keeps up. Revealing per key costs
// about 22 ms each, five seconds of work for every second of typing. The
// 1.3 ms that remains is the edit itself and what `area_changed` does with
// it.
//
//   ./build.sh spike typing_cost run
package main

import "core:fmt"
import "core:strings"
import "core:time"
import "baldr:baldr"

Msg :: union { int }

KEYS :: 200

main :: proc() {
	// Without a text engine block_spans takes its no-fonts fallback and
	// measures nothing at all — the whole cost here is shaping.
	te: baldr.Text_Engine
	if !baldr.text_engine_init(&te) { fmt.println("fonts failed to load"); return }
	defer baldr.text_engine_destroy(&te)

	ui: baldr.Ui(Msg)
	baldr.ui_init(&ui)
	defer baldr.ui_destroy(&ui)
	ui.tree.text = &te

	para := strings.repeat("the quick brown fox jumps over the lazy dog. ", 41) // ~1,800 chars
	defer delete(para)
	doc := baldr.document_make(para)
	defer baldr.document_destroy(&doc)

	n: baldr.Node
	view :: proc(ui: ^baldr.Ui(Msg), doc: ^baldr.Document) -> baldr.Node {
		baldr.set_viewport(&ui.tree, {600, 400})
		baldr.begin_view(ui)
		baldr.column(ui, padding = .lg)
		n := baldr.text_area(ui, doc, label = "Composer", width = 520, height = 160)
		baldr.end(ui)
		baldr.end_view(ui)
		baldr.frame(&ui.tree, {600, 400})
		return n
	}
	n = view(&ui, &doc)
	baldr.set_focus(&ui.tree, n, true)
	n = view(&ui, &doc)

	// the caret at the very end, which is where a composer's is
	end := baldr.Pos{0, len(para)}
	baldr.editor_select(&ui, n, end, end)
	n = view(&ui, &doc)

	// How much does a caret move cost when the document has NOT changed?
	// If the shaping cache still holds, it should be nearly free — which
	// would mean only edits need coalescing.
	mstart := time.tick_now()
	for i in 0 ..< KEYS {
		p := baldr.Pos{0, len(para) - (i % 100) - 1}
		baldr.editor_select(&ui, n, p, p)
	}
	moves := time.tick_since(mstart)
	fmt.printfln("%d caret moves, document unchanged: %.1f ms (%.4f ms/move)",
		KEYS, time.duration_milliseconds(moves), time.duration_milliseconds(moves) / KEYS)

	fmt.printfln("paragraph: %d bytes; typing %d characters as one burst", len(para), KEYS)
	start := time.tick_now()
	for i in 0 ..< KEYS do baldr.text_area_text(&ui, "x")
	burst := time.tick_since(start)

	start = time.tick_now()
	n = view(&ui, &doc) // the one layout that settles it
	settle := time.tick_since(start)

	fmt.printfln("  the %d keys:        %.1f ms  (%.4f ms/key)",
		KEYS, time.duration_milliseconds(burst), time.duration_milliseconds(burst) / KEYS)
	fmt.printfln("  the layout after:   %.1f ms", time.duration_milliseconds(settle))
	fmt.printfln("  total:              %.1f ms", time.duration_milliseconds(burst + settle))
}
