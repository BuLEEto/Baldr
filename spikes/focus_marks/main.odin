// focus_marks — marks that fade, tint or strike the words.
//
// Sentence focus: everything but the sentence the
// caret is in is drawn faded, and the fade follows the caret. Type or move
// the caret and watch it move — which needs `editor_options(follow_caret =
// true)`, because a caret move only repaints otherwise and the app would
// never get to say where the fade goes now. The buttons add a tint over the adverbs and
// a strike through the fillers, so all three kinds can be seen at once and
// judged against each other.
//
//   ./build.sh spike focus_marks run
package main

import "core:strings"
import "baldr:baldr"

TEXT :: `Writing is thinking. The first draft is really just you telling yourself the story. A draft at 3.5 pages is quite fine, e.g. this one.

Very few sentences survive contact with a second reading, and that is quite fine. Cut the fillers, keep the verbs, and the paragraph will basically carry itself.`

ADVERBS := []string{"really", "quite", "basically"}
FILLERS := []string{"Very few", "just"}

State :: struct {
	doc:     baldr.Document,
	focus:   bool,
	adverbs: bool,
	fillers: bool,
}

Msg :: union { Focus, Adverbs, Fillers }
Focus   :: struct { on: bool }
Adverbs :: struct { on: bool }
Fillers :: struct { on: bool }

// sentence_end says whether the terminator at `i` really ends a sentence:
// only when what follows it is a space or the end of the line, so "3.5"
// stays whole. Any closing quotes or brackets go with the sentence they
// end, not with the next one.
//
// It is not enough for real prose: "e.g. this one" splits after the second
// dot, because that dot *is* followed by a space, and knowing it is an
// abbreviation needs a list. The text editor has stricter rules.
sentence_end :: proc(s: string, i: int) -> (end: int, ok: bool) {
	if i >= len(s) || !strings.contains_rune(".!?", rune(s[i])) do return
	end = i + 1
	for end < len(s) && strings.contains_rune("\"')]}", rune(s[end])) do end += 1 // "…that." keeps its quote
	if end < len(s) && s[end] != ' ' && s[end] != '\t' && s[end] != '\n' do return 0, false
	return end, true
}

// sentence_at is the range of the sentence holding `off` in `s`.
sentence_at :: proc(s: string, off: int) -> (from, to: int) {
	from = 0
	for i in 0 ..< min(off, len(s)) {
		if e, ok := sentence_end(s, i); ok && e <= off {
			from = e
			for from < len(s) && (s[from] == ' ' || s[from] == '\t') do from += 1
		}
	}
	to = len(s)
	for i in off ..< len(s) {
		if e, ok := sentence_end(s, i); ok {
			to = e
			break
		}
	}
	return
}

main :: proc() {
	baldr.run(baldr.App(State, Msg){
		title = "Focus marks", app_id = "baldr.focusmarks", size = {720, 460},
		init = proc() -> State {
			s := State{focus = true, adverbs = true, fillers = true}
			s.doc = baldr.document_make(TEXT)
			return s
		},
		update = proc(s: ^State, m: Msg) -> baldr.Cmd(Msg) {
			switch v in m {
			case Focus:   s.focus = v.on
			case Adverbs: s.adverbs = v.on
			case Fillers: s.fillers = v.on
			}
			return {}
		},
		view = proc(s: ^State, ui: ^baldr.Ui(Msg)) {
			baldr.column(ui, gap = .md, padding = .lg, flex = 1); defer baldr.end(ui)
			baldr.text(ui, "Sentence focus", role = .Headline)
			baldr.row(ui, gap = .lg); {
				defer baldr.end(ui)
				baldr.toggle(ui, s.focus, "Fade the rest", proc(e: baldr.Ev(bool)) -> Msg { return Focus{e.value} })
				baldr.toggle(ui, s.adverbs, "Tint adverbs", proc(e: baldr.Ev(bool)) -> Msg { return Adverbs{e.value} })
				baldr.toggle(ui, s.fillers, "Strike fillers", proc(e: baldr.Ev(bool)) -> Msg { return Fillers{e.value} })
			}

			ed := baldr.markdown_editor(ui, &s.doc, label = "Draft", flex = 1)
			// The fade follows the caret, so the view has to run again when it
			// moves — a caret move only repaints otherwise, which is what
			// every editor that draws nothing from it wants.
			baldr.editor_options(ui, ed, follow_caret = true)
			marks := make([dynamic]baldr.Mark, context.temp_allocator)

			// The tints go on first; the fade is added after so it wins over
			// them, which is what "the last one wins" is for.
			for bi in 0 ..< baldr.block_count(&s.doc) {
				body := baldr.block_str(&s.doc, bi)
				if s.adverbs do for word in ADVERBS {
					at := 0
					for {
						i := strings.index(body[at:], word)
						if i < 0 do break
						append(&marks, baldr.Mark{from = {bi, at + i}, to = {bi, at + i + len(word)},
							kind = .Tint, color = {0.36, 0.62, 0.92, 1}})
						at += i + len(word)
					}
				}
				if s.fillers do for word in FILLERS {
					if i := strings.index(body, word); i >= 0 {
						append(&marks, baldr.Mark{from = {bi, i}, to = {bi, i + len(word)}, kind = .Strike})
					}
				}
			}

			if s.focus {
				// The caret is the app's to read: sentence focus is a fade
				// that follows it, so it has to know where it is.
				caret, _, has := baldr.editor_caret(&ui.tree, ed)
				if !has do return
				body := baldr.block_str(&s.doc, caret.block)
				from, to := sentence_at(body, caret.off)
				// Everything but the caret's sentence: the blocks either side
				// whole, and this block's text before and after it.
				for bi in 0 ..< baldr.block_count(&s.doc) {
					if bi == caret.block do continue
					n := len(baldr.block_str(&s.doc, bi))
					append(&marks, baldr.Mark{from = {bi, 0}, to = {bi, n}, kind = .Dim})
				}
				if from > 0 do append(&marks, baldr.Mark{from = {caret.block, 0}, to = {caret.block, from}, kind = .Dim})
				if to < len(body) do append(&marks, baldr.Mark{from = {caret.block, to}, to = {caret.block, len(body)}, kind = .Dim})
			}
			baldr.editor_marks(ui, ed, marks[:])
		},
	})
}
